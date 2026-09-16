import {
  BadRequestException,
  ConflictException,
  Injectable,
  InternalServerErrorException,
  NotFoundException,
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { pipeline, Readable, Transform, Writable } from 'node:stream';
import sanitize from 'sanitize-filename';
import type { UploadFile, UploadRequest } from 'src/types.js';
import { StorageCore } from 'src/cores/storage.core.js';
import { Asset, AuthSharedLink } from 'src/database.js';
import { OnEvent, OnJob } from 'src/decorators.js';
import {
  AssetBulkUploadCheckResponseDto,
  AssetMediaResponseDto,
  AssetMediaStatus,
  AssetRejectReason,
  AssetUploadAction,
} from 'src/dtos/asset-media-response.dto.js';
import {
  AssetBulkUploadCheckDto,
  AssetMediaCreateDto,
  AssetMediaOptionsDto,
  AssetMediaSize,
  AssetMediaUploadInitDto,
  UploadFieldName,
} from 'src/dtos/asset-media.dto.js';
import { AssetDownloadOriginalDto } from 'src/dtos/asset.dto.js';
import { AuthDto } from 'src/dtos/auth.dto.js';
import {
  AssetFileType,
  AssetVisibility,
  CacheControl,
  ChecksumAlgorithm,
  ImmichWorker,
  JobName,
  JobStatus,
  Permission,
  QueueName,
  StorageFolder,
} from 'src/enum.js';
import { AuthRequest } from 'src/middleware/auth.guard.js';
import { BaseService } from 'src/services/base.service.js';
import { requireUploadAccess } from 'src/utils/access.js';
import { asUploadRequest, onBeforeLink } from 'src/utils/asset.util.js';
import { isAssetChecksumConstraint } from 'src/utils/database.js';
import { ImmichFileResponse, getFileNameWithoutExtension, getFilenameExtension } from 'src/utils/file.js';
import { handlePromiseError } from 'src/utils/misc.js';
import { mimeTypes } from 'src/utils/mime-types.js';
import { fromChecksum } from 'src/utils/request.js';

export interface AssetMediaRedirectResponse {
  targetSize: AssetMediaSize | 'original';
}

@Injectable()
export class AssetMediaService extends BaseService {
  async getUploadAssetIdByChecksum(auth: AuthDto, checksum?: string): Promise<AssetMediaResponseDto | undefined> {
    if (!checksum) {
      return;
    }

    const assetId = await this.assetRepository.getUploadAssetIdByChecksum(auth.user.id, fromChecksum(checksum));
    if (!assetId) {
      return;
    }

    return { id: assetId, status: AssetMediaStatus.DUPLICATE };
  }

  canUploadFile({ auth, fieldName, file, body }: UploadRequest): true {
    requireUploadAccess(auth);

    const filename = body.filename || file.originalName;

    switch (fieldName) {
      case UploadFieldName.ASSET_DATA: {
        if (mimeTypes.isAsset(filename)) {
          return true;
        }
        break;
      }

      case UploadFieldName.SIDECAR_DATA: {
        if (mimeTypes.isSidecar(filename)) {
          return true;
        }
        break;
      }

      case UploadFieldName.PROFILE_DATA: {
        if (mimeTypes.isProfile(filename)) {
          return true;
        }
        break;
      }
    }

    this.logger.error(`Unsupported file type ${filename}`);
    throw new BadRequestException(`Unsupported file type ${filename}`);
  }

  getUploadFilename({ auth, fieldName, file, body }: UploadRequest): string {
    requireUploadAccess(auth);

    const extension = getFilenameExtension(body.filename || file.originalName);
    const lookup = {
      [UploadFieldName.ASSET_DATA]: extension,
      [UploadFieldName.SIDECAR_DATA]: '.xmp',
      [UploadFieldName.PROFILE_DATA]: extension,
    };

    return sanitize(`${file.uuid}${lookup[fieldName]}`);
  }

  getUploadFolder({ auth, fieldName, file }: UploadRequest): string {
    auth = requireUploadAccess(auth);

    let folder = StorageCore.getNestedFolder(StorageFolder.Upload, auth.user.id, file.uuid);
    if (fieldName === UploadFieldName.PROFILE_DATA) {
      folder = StorageCore.getFolderLocation(StorageFolder.Profile, auth.user.id);
    }

    this.storageRepository.mkdirSync(folder);

    return folder;
  }

  async onUploadError(request: AuthRequest, file: Express.Multer.File) {
    const uploadFilename = this.getUploadFilename(asUploadRequest(request, file));
    const uploadFolder = this.getUploadFolder(asUploadRequest(request, file));
    const uploadPath = `${uploadFolder}/${uploadFilename}`;

    await this.jobRepository.queue({ name: JobName.FileDelete, data: { files: [uploadPath] } });
  }

  async uploadAsset(
    auth: AuthDto,
    dto: AssetMediaCreateDto,
    file: UploadFile,
    sidecarFile?: UploadFile,
  ): Promise<AssetMediaResponseDto> {
    let asset: Asset | undefined;
    try {
      await this.requireAccess({
        auth,
        permission: Permission.AssetUpload,
        // do not need an id here, but the interface requires it
        ids: [auth.user.id],
      });

      this.requireQuota(auth, file.size);

      if (dto.livePhotoVideoId) {
        await onBeforeLink(
          { asset: this.assetRepository, event: this.eventRepository },
          { userId: auth.user.id, livePhotoVideoId: dto.livePhotoVideoId },
        );
      }

      asset = await this.assetRepository.create({
        ownerId: auth.user.id,
        libraryId: null,

        checksum: file.checksum,
        checksumAlgorithm: ChecksumAlgorithm.sha1File,
        originalPath: file.originalPath,

        fileCreatedAt: dto.fileCreatedAt,
        fileModifiedAt: dto.fileModifiedAt,
        localDateTime: dto.fileCreatedAt,

        type: mimeTypes.assetType(file.originalPath),
        isFavorite: dto.isFavorite,
        duration: dto.duration || null,
        visibility: dto.visibility ?? AssetVisibility.Timeline,
        livePhotoVideoId: dto.livePhotoVideoId,
        originalFileName: dto.filename || file.originalName,
      });

      if (dto.metadata?.length) {
        await this.assetRepository.upsertMetadata(asset.id, dto.metadata);
      }

      if (sidecarFile) {
        await this.assetRepository.upsertFile({
          assetId: asset.id,
          path: sidecarFile.originalPath,
          type: AssetFileType.Sidecar,
        });
        await this.storageRepository.utimes(sidecarFile.originalPath, new Date(), new Date(dto.fileModifiedAt));
      }
      await this.storageRepository.utimes(file.originalPath, new Date(), new Date(dto.fileModifiedAt));
      await this.assetRepository.upsertExif({
        exif: { assetId: asset.id, fileSizeInByte: file.size },
        lockedPropertiesBehavior: 'override',
      });

      await this.jobRepository.queue({ name: JobName.AssetExtractMetadata, data: { id: asset.id, source: 'upload' } });

      if (auth.sharedLink) {
        await this.addToSharedLink(auth.sharedLink, asset.id);
      }

      await this.eventRepository.emit('AssetCreate', { asset, file });

      return { id: asset.id, status: AssetMediaStatus.CREATED };
    } catch (error: any) {
      // clean up files
      await this.jobRepository.queue({
        name: JobName.FileDelete,
        data: { files: [file.originalPath, sidecarFile?.originalPath] },
      });

      // handle duplicates with a success response
      if (isAssetChecksumConstraint(error)) {
        const duplicateId = await this.assetRepository.getUploadAssetIdByChecksum(auth.user.id, file.checksum);
        if (!duplicateId) {
          this.logger.error(`Error locating duplicate for checksum constraint`);
          throw new InternalServerErrorException();
        }

        if (auth.sharedLink) {
          await this.addToSharedLink(auth.sharedLink, duplicateId);
        }

        this.logger.debug(`Duplicate asset upload rejected: existing asset ${duplicateId}`);
        return { status: AssetMediaStatus.DUPLICATE, id: duplicateId };
      }

      // clean up the asset row if one was created
      if (asset) {
        await this.assetRepository.remove({ id: asset.id });
      }

      this.logger.error(`Error uploading file ${error}`, error?.stack);
      throw error;
    }
  }

  async downloadOriginal(auth: AuthDto, id: string, dto: AssetDownloadOriginalDto): Promise<ImmichFileResponse> {
    await this.requireAccess({ auth, permission: Permission.AssetDownload, ids: [id] });

    if (auth.sharedLink) {
      dto.edited = true;
    }

    const { originalPath, originalFileName, editedPath } = await this.assetRepository.getForOriginal(
      id,
      dto.edited ?? false,
    );

    const path = editedPath ?? originalPath!;

    return new ImmichFileResponse({
      path,
      fileName: getFileNameWithoutExtension(originalFileName) + getFilenameExtension(path),
      contentType: mimeTypes.lookup(path),
      cacheControl: CacheControl.PrivateWithCache,
    });
  }

  async viewThumbnail(
    auth: AuthDto,
    id: string,
    dto: AssetMediaOptionsDto,
  ): Promise<ImmichFileResponse | AssetMediaRedirectResponse> {
    await this.requireAccess({ auth, permission: Permission.AssetView, ids: [id] });

    if (dto.size === AssetMediaSize.Original) {
      throw new BadRequestException('May not request original file');
    }

    if (auth.sharedLink) {
      dto.edited = true;
    }

    const size = (dto.size ?? AssetMediaSize.THUMBNAIL) as unknown as AssetFileType;
    const { originalPath, originalFileName, path } = await this.assetRepository.getForThumbnail(
      id,
      size,
      dto.edited ?? false,
    );

    if (size === AssetFileType.FullSize && mimeTypes.isWebSupportedImage(originalPath) && !dto.edited) {
      // use original file for web supported images
      return { targetSize: 'original' };
    }

    if (dto.size === AssetMediaSize.FULLSIZE && !path) {
      // downgrade to preview if fullsize is not available.
      // e.g. disabled or not yet (re)generated
      return { targetSize: AssetMediaSize.PREVIEW };
    }

    if (!path) {
      throw new NotFoundException('Asset media not found');
    }

    const fileNameBase =
      auth.sharedLink && !auth.sharedLink.showExif ? id : getFileNameWithoutExtension(originalFileName);
    const fileName = `${fileNameBase}_${size}${getFilenameExtension(path)}`;

    return new ImmichFileResponse({
      fileName,
      path,
      contentType: mimeTypes.lookup(path),
      cacheControl: CacheControl.PrivateWithCache,
    });
  }

  async playbackVideo(auth: AuthDto, id: string): Promise<ImmichFileResponse> {
    await this.requireAccess({ auth, permission: Permission.AssetView, ids: [id] });

    const asset = await this.assetRepository.getForVideo(id);

    if (!asset) {
      throw new NotFoundException('Asset not found or asset is not a video');
    }

    const filepath = asset.encodedVideoPath || asset.originalPath;

    return new ImmichFileResponse({
      path: filepath,
      contentType: mimeTypes.lookup(filepath),
      cacheControl: CacheControl.PrivateWithCache,
    });
  }

  async bulkUploadCheck(auth: AuthDto, dto: AssetBulkUploadCheckDto): Promise<AssetBulkUploadCheckResponseDto> {
    const checksums: Buffer[] = dto.assets.map((asset) => fromChecksum(asset.checksum));
    const results = await this.assetRepository.getByChecksums(auth.user.id, checksums);
    const checksumMap: Record<string, { id: string; isTrashed: boolean }> = {};

    for (const { id, deletedAt, checksum } of results) {
      checksumMap[checksum.toString('hex')] = { id, isTrashed: !!deletedAt };
    }

    return {
      results: dto.assets.map(({ id, checksum }) => {
        const duplicate = checksumMap[fromChecksum(checksum).toString('hex')];
        if (duplicate) {
          return {
            id,
            action: AssetUploadAction.REJECT,
            reason: AssetRejectReason.DUPLICATE,
            assetId: duplicate.id,
            isTrashed: duplicate.isTrashed,
          };
        }

        return {
          id,
          action: AssetUploadAction.ACCEPT,
        };
      }),
    };
  }

  async initChunkedUpload(auth: AuthDto, dto: AssetMediaUploadInitDto): Promise<{ uploadId: string }> {
    const start = Date.now();
    auth = requireUploadAccess(auth);
    const uploadId = randomUUID();
    const { folder, manifestPath } = this.getChunkedUploadPaths(auth, uploadId);
    this.logger.log(
      `[chunked-upload] init ENTRY t=${new Date().toISOString()} filename=${dto.filename} totalSize=${dto.totalSize ?? 'n/a'} chunkCount=${dto.chunkCount} chunkSize=${dto.chunkSize} hashesProvided=${dto.chunkHashes.length}`,
    );
    this.storageRepository.mkdirSync(folder);
    await this.storageRepository.createOrOverwriteFile(
      manifestPath,
      Buffer.from(
        JSON.stringify({
          chunkCount: dto.chunkCount,
          chunkSize: dto.chunkSize,
          chunkHashes: dto.chunkHashes,
        }),
      ),
    );
    this.logger.log(
      `[chunked-upload] init EXIT uploadId=${uploadId} folder=${folder} manifest=${manifestPath} elapsedMs=${Date.now() - start}`,
    );
    return { uploadId };
  }

  async uploadChunk(auth: AuthDto, uploadId: string, offset: number, request: Readable): Promise<{ offset: number }> {
    const start = Date.now();
    auth = requireUploadAccess(auth);
    const { folder, partialPath, manifestPath } = this.getChunkedUploadPaths(auth, uploadId);
    this.storageRepository.mkdirSync(folder);

    let current = 0;
    if (this.storageRepository.existsSync(partialPath)) {
      const { size } = await this.storageRepository.stat(partialPath);
      current = size;
    }
    this.logger.log(
      `[chunked-upload] append ENTRY uploadId=${uploadId} offset=${offset} committed=${current} t=${new Date().toISOString()}`,
    );
    if (offset !== current) {
      this.logger.warn(
        `[chunked-upload] append OFFSET-MISMATCH uploadId=${uploadId} offset=${offset} committed=${current}`,
      );
      throw new ConflictException({ offset: current });
    }

    const manifest = await this.readChunkedUploadManifest(manifestPath);

    const hash = createHash('sha256');
    await new Promise<void>((resolve, reject) => {
      pipeline(
        request,
        new Transform({
          transform(chunk, _encoding, callback) {
            hash.update(chunk);
            callback(null, chunk);
          },
        }),
        this.storageRepository.createAppendStream(partialPath),
        (error) => (error ? reject(error) : resolve()),
      );
    });

    if (manifest) {
      const chunkIndex = Math.floor(offset / manifest.chunkSize);
      const receivedHash = hash.digest('hex');
      if (receivedHash !== manifest.chunkHashes[chunkIndex]) {
        this.logger.error(
          `[chunked-upload] append sha256 FAIL uploadId=${uploadId} chunkIndex=${chunkIndex} offset=${offset} expected=${manifest.chunkHashes[chunkIndex]} received=${receivedHash}`,
        );
        throw new ConflictException({ chunkIndex });
      }
      this.logger.log(`[chunked-upload] append sha256 PASS uploadId=${uploadId} chunkIndex=${chunkIndex}`);
    }

    const { size } = await this.storageRepository.stat(partialPath);
    this.logger.log(
      `[chunked-upload] append EXIT uploadId=${uploadId} offset=${offset} bytesReceived=${size - offset} committed=${size} elapsedMs=${Date.now() - start}`,
    );
    return { offset: size };
  }

  async getChunkedUploadStatus(auth: AuthDto, uploadId: string): Promise<{ offset: number }> {
    const start = Date.now();
    auth = requireUploadAccess(auth);
    const { partialPath, manifestPath } = this.getChunkedUploadPaths(auth, uploadId);
    this.logger.log(`[chunked-upload] status ENTRY uploadId=${uploadId} t=${new Date().toISOString()}`);

    let expectedTotal = 'n/a';
    try {
      const manifest = await this.readChunkedUploadManifest(manifestPath);
      if (manifest) {
        expectedTotal = `${manifest.chunkCount * manifest.chunkSize}`;
      }
    } catch (error: any) {
      this.logger.warn(`[chunked-upload] status manifest-read FAIL uploadId=${uploadId}: ${error?.message ?? error}`);
    }

    if (!this.storageRepository.existsSync(partialPath)) {
      this.logger.log(
        `[chunked-upload] status EXIT uploadId=${uploadId} offset=0 expected=${expectedTotal} elapsedMs=${Date.now() - start}`,
      );
      return { offset: 0 };
    }
    const { size } = await this.storageRepository.stat(partialPath);
    this.logger.log(
      `[chunked-upload] status EXIT uploadId=${uploadId} offset=${size} expected=${expectedTotal} elapsedMs=${Date.now() - start}`,
    );
    return { offset: size };
  }

  async finalizeChunkedUpload(
    auth: AuthDto,
    uploadId: string,
    dto: AssetMediaCreateDto,
  ): Promise<AssetMediaResponseDto> {
    const start = Date.now();
    auth = requireUploadAccess(auth);
    const { folder, partialPath, manifestPath } = this.getChunkedUploadPaths(auth, uploadId);
    const finalPath = StorageCore.getNestedPath(
      StorageFolder.Upload,
      auth.user.id,
      `${uploadId}${getFilenameExtension(dto.filename || '')}`,
    );
    this.storageRepository.mkdirSync(folder);

    this.logger.log(`[chunked-upload] finalize ENTRY uploadId=${uploadId} filename=${dto.filename} t=${new Date().toISOString()}`);

    if (!this.storageRepository.existsSync(partialPath)) {
      this.logger.error(`[chunked-upload] finalize FAIL uploadId=${uploadId} reason=partialNotFound`);
      throw new NotFoundException('Chunked upload not found');
    }

    let expectedBytes = 'n/a';
    let receivedBytes = 'n/a';
    try {
      const manifest = await this.readChunkedUploadManifest(manifestPath);
      if (manifest) {
        expectedBytes = `${manifest.chunkCount * manifest.chunkSize}`;
      }
      const { size } = await this.storageRepository.stat(partialPath);
      receivedBytes = `${size}`;
    } catch (error: any) {
      this.logger.error(
        `[chunked-upload] finalize size-check ERROR uploadId=${uploadId} message=${error?.message ?? error}`,
        error?.stack,
      );
    }
    this.logger.log(
      `[chunked-upload] finalize bytes uploadId=${uploadId} expected=${expectedBytes} received=${receivedBytes}`,
    );

    try {
      await this.storageRepository.rename(partialPath, finalPath);
      await this.storageRepository.unlink(manifestPath);

      const { checksum, size } = await this.hashFile(finalPath);
      this.logger.log(
        `[chunked-upload] finalize hash uploadId=${uploadId} finalPath=${finalPath} size=${size} sha1=${checksum.toString('hex')}`,
      );

      const result = await this.uploadAsset(auth, dto, {
        uuid: uploadId,
        checksum,
        originalPath: finalPath,
        originalName: dto.filename || '',
        size,
      });

      this.logger.log(
        `[chunked-upload] finalize EXIT uploadId=${uploadId} status=${result.status} assetId=${result.id} elapsedMs=${Date.now() - start}`,
      );
      return result;
    } catch (error: any) {
      this.logger.error(
        `[chunked-upload] finalize ERROR uploadId=${uploadId} message=${error?.message ?? error} stack=${error?.stack}`,
        error?.stack,
      );
      throw error;
    }
  }

  async deleteChunkedUpload(auth: AuthDto, uploadId: string): Promise<void> {
    const start = Date.now();
    auth = requireUploadAccess(auth);
    const { partialPath, manifestPath } = this.getChunkedUploadPaths(auth, uploadId);
    this.logger.log(`[chunked-upload] delete ENTRY uploadId=${uploadId} t=${new Date().toISOString()}`);
    await this.storageRepository.unlink(partialPath);
    await this.storageRepository.unlink(manifestPath);
    this.logger.log(`[chunked-upload] delete EXIT uploadId=${uploadId} elapsedMs=${Date.now() - start}`);
  }

  @OnEvent({ name: 'AppBootstrap', workers: [ImmichWorker.Microservices] })
  onBootstrap(): void {
    this.cronRepository.create({
      name: 'chunkedUploadCleanup',
      expression: '0 */6 * * *',
      onTick: () =>
        handlePromiseError(this.jobRepository.queue({ name: JobName.ChunkedUploadCleanup, data: {} }), this.logger),
    });
  }

  @OnJob({ name: JobName.ChunkedUploadCleanup, queue: QueueName.BackgroundTask })
  async handleChunkedUploadCleanup(): Promise<JobStatus> {
    const uploadFolder = StorageCore.getBaseFolder(StorageFolder.Upload);
    const cutoffMs = Date.now() - 24 * 60 * 60 * 1000;
    let removed = 0;

    await this.removeStalePartFiles(uploadFolder, cutoffMs, () => {
      removed += 1;
    });

    if (removed > 0) {
      await this.storageRepository.removeEmptyDirs(uploadFolder);
    }

    this.logger.log(`[chunked-upload] cleanup removed ${removed} stale part file(s)`);
    return JobStatus.Success;
  }

  private async removeStalePartFiles(folder: string, cutoffMs: number, onRemove: () => void): Promise<void> {
    const entries = await this.storageRepository.readdirWithTypes(folder).catch(() => []);

    for (const entry of entries) {
      const fullPath = path.join(folder, entry.name);
      if (entry.isDirectory()) {
        await this.removeStalePartFiles(fullPath, cutoffMs, onRemove);
        continue;
      }

      if (!entry.name.endsWith('.part') && !entry.name.endsWith('.manifest')) {
        continue;
      }

      try {
        const stats = await this.storageRepository.stat(fullPath);
        if (stats.mtimeMs < cutoffMs) {
          await this.storageRepository.unlink(fullPath);
          onRemove();
          this.logger.log(`[chunked-upload] cleanup removed stale file ${fullPath}`);
        }
      } catch (error) {
        this.logger.debug(`[chunked-upload] cleanup skipped ${fullPath}: ${error}`);
      }
    }
    
  }
  private getChunkedUploadPaths(auth: AuthDto, uploadId: string) {
    return {
      folder: StorageCore.getNestedFolder(StorageFolder.Upload, auth.user.id, uploadId),
      partialPath: StorageCore.getNestedPath(StorageFolder.Upload, auth.user.id, `${uploadId}.part`),
      manifestPath: StorageCore.getNestedPath(StorageFolder.Upload, auth.user.id, `${uploadId}.manifest`),
    };
  }

  private async readChunkedUploadManifest(
    manifestPath: string,
  ): Promise<{ chunkCount: number; chunkSize: number; chunkHashes: string[] } | null> {
    if (!this.storageRepository.existsSync(manifestPath)) {
      return null;
    }
    return this.storageRepository.readJsonFile<{ chunkCount: number; chunkSize: number; chunkHashes: string[] }>(
      manifestPath,
    );
  }

  private async hashFile(filepath: string): Promise<{ checksum: Buffer; size: number }> {
    const hash = createHash('sha1');
    await new Promise<void>((resolve, reject) => {
      pipeline(
        this.storageRepository.createPlainReadStream(filepath),
        new Writable({
          write(chunk, _encoding, callback) {
            hash.update(chunk);
            callback();
          },
        }),
        (error) => (error ? reject(error) : resolve()),
      );
    });
    const { size } = await this.storageRepository.stat(filepath);
    return { checksum: hash.digest(), size };
  }

  private async addToSharedLink(sharedLink: AuthSharedLink, assetId: string) {
    if (!sharedLink.albumId) {
      await this.sharedLinkRepository.addAssets(sharedLink.id, [assetId]);
      return;
    }

    const album = await this.albumRepository.getById(sharedLink.albumId, { withAssets: false });
    if (!album) {
      return;
    }

    await this.albumRepository.addAssetIds(album.id, [assetId]);
    const userIds = album.albumUsers.map(({ user }) => user.id);
    await this.eventRepository.emit('AlbumUpdate', {
      id: album.id,
      userIds,
      recipientIds: userIds,
    });
  }

  private requireQuota(auth: AuthDto, size: number) {
    if (auth.user.quotaSizeInBytes !== null && auth.user.quotaSizeInBytes < auth.user.quotaUsageInBytes + size) {
      throw new BadRequestException('Quota has been exceeded!');
    }
  }
}
