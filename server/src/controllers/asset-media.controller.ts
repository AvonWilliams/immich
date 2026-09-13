import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Next,
  Param,
  ParseFilePipe,
  Post,
  Put,
  Query,
  Req,
  Res,
  UploadedFiles,
  UseInterceptors,
} from '@nestjs/common';
import { ApiBody, ApiConsumes, ApiHeader, ApiResponse, ApiTags } from '@nestjs/swagger';
import { NextFunction, Request, Response } from 'express';
import { Endpoint, HistoryBuilder } from 'src/decorators';
import {
  AssetBulkUploadCheckResponseDto,
  AssetMediaResponseDto,
  AssetMediaStatus,
} from 'src/dtos/asset-media-response.dto';
import {
  AssetBulkUploadCheckDto,
  AssetMediaCreateDto,
  AssetMediaOptionsDto,
  AssetMediaSize,
  AssetMediaUploadInitDto,
  AssetMediaUploadParamDto,
  AssetMediaUploadQueryDto,
} from 'src/dtos/asset-media.dto';
import { AssetDownloadOriginalDto } from 'src/dtos/asset.dto';
import { AuthDto } from 'src/dtos/auth.dto';
import { ApiTag, ImmichHeader, Permission, RouteKey } from 'src/enum';
import { AssetUploadInterceptor } from 'src/middleware/asset-upload.interceptor';
import { Auth, Authenticated, FileResponse } from 'src/middleware/auth.guard';
import { FileUploadInterceptor, getFiles } from 'src/middleware/file-upload.interceptor';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { AssetMediaService } from 'src/services/asset-media.service';
import { UploadFiles } from 'src/types';
import { ImmichFileResponse, sendFile } from 'src/utils/file';
import { FileNotEmptyValidator, UUIDParamDto } from 'src/validation';

@ApiTags(ApiTag.Assets)
@Controller(RouteKey.Asset)
export class AssetMediaController {
  constructor(
    private logger: LoggingRepository,
    private service: AssetMediaService,
  ) {}

  @Post()
  @Authenticated({ permission: Permission.AssetUpload, sharedLink: true })
  @UseInterceptors(AssetUploadInterceptor, FileUploadInterceptor)
  @ApiConsumes('multipart/form-data')
  @ApiHeader({
    name: ImmichHeader.Checksum,
    description: 'sha1 checksum that can be used for duplicate detection before the file is uploaded',
    required: false,
  })
  @ApiBody({ description: 'Asset Upload Information', type: AssetMediaCreateDto })
  @ApiResponse({
    status: 200,
    description: 'Asset is a duplicate',
    type: AssetMediaResponseDto,
  })
  @ApiResponse({
    status: 201,
    description: 'Asset uploaded successfully',
    type: AssetMediaResponseDto,
  })
  @Endpoint({
    summary: 'Upload asset',
    description: 'Uploads a new asset to the server.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  async uploadAsset(
    @Auth() auth: AuthDto,
    @UploadedFiles(new ParseFilePipe({ validators: [new FileNotEmptyValidator(['assetData'])] })) files: UploadFiles,
    @Body() dto: AssetMediaCreateDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AssetMediaResponseDto> {
    const { file, sidecarFile } = getFiles(files);
    const responseDto = await this.service.uploadAsset(auth, dto, file, sidecarFile);

    if (responseDto.status === AssetMediaStatus.DUPLICATE) {
      res.status(HttpStatus.OK);
    }

    return responseDto;
  }

  @Post('upload')
  @Authenticated({ permission: Permission.AssetUpload, sharedLink: true })
  @ApiBody({ description: 'Chunked upload initialization', type: AssetMediaUploadInitDto })
  @ApiResponse({ status: 201, description: 'Chunked upload session initialized' })
  @Endpoint({
    summary: 'Initialize chunked upload',
    description: 'Creates a new chunked upload session for the given asset.',
    history: new HistoryBuilder().added('v3.1.0').beta('v3.1.0'),
  })
  initChunkedUpload(@Auth() auth: AuthDto, @Body() dto: AssetMediaUploadInitDto): Promise<{ uploadId: string }> {
    return this.service.initChunkedUpload(auth, dto);
  }

  @Put('upload/:uploadId')
  @Authenticated({ permission: Permission.AssetUpload, sharedLink: true })
  @ApiConsumes('application/octet-stream')
  @ApiResponse({ status: 200, description: 'Chunk appended successfully' })
  @ApiResponse({ status: 409, description: 'Byte offset does not match the committed size' })
  @Endpoint({
    summary: 'Upload a chunk',
    description: 'Appends a chunk of binary data to the given chunked upload session.',
    history: new HistoryBuilder().added('v3.1.0').beta('v3.1.0'),
  })
  async uploadChunk(
    @Auth() auth: AuthDto,
    @Param() { uploadId }: AssetMediaUploadParamDto,
    @Query() { offset }: AssetMediaUploadQueryDto,
    @Req() req: Request,
  ): Promise<{ offset: number }> {
    return this.service.uploadChunk(auth, uploadId, offset, req);
  }

  @Get('upload/:uploadId')
  @Authenticated({ permission: Permission.AssetUpload, sharedLink: true })
  @ApiResponse({ status: 200, description: 'Chunked upload status' })
  @Endpoint({
    summary: 'Get chunked upload status',
    description: 'Returns the number of bytes committed so far for the given chunked upload session.',
    history: new HistoryBuilder().added('v3.1.0').beta('v3.1.0'),
  })
  getChunkedUploadStatus(
    @Auth() auth: AuthDto,
    @Param() { uploadId }: AssetMediaUploadParamDto,
  ): Promise<{ offset: number }> {
    return this.service.getChunkedUploadStatus(auth, uploadId);
  }

  @Post('upload/:uploadId/finalize')
  @Authenticated({ permission: Permission.AssetUpload, sharedLink: true })
  @UseInterceptors(FileUploadInterceptor)
  @ApiConsumes('multipart/form-data')
  @ApiBody({ description: 'Chunked upload finalization', type: AssetMediaCreateDto })
  @ApiResponse({
    status: 200,
    description: 'Asset is a duplicate',
    type: AssetMediaResponseDto,
  })
  @ApiResponse({
    status: 201,
    description: 'Asset uploaded successfully',
    type: AssetMediaResponseDto,
  })
  @Endpoint({
    summary: 'Finalize chunked upload',
    description: 'Assembles the uploaded chunks and creates a new asset.',
    history: new HistoryBuilder().added('v3.1.0').beta('v3.1.0'),
  })
  async finalizeChunkedUpload(
    @Auth() auth: AuthDto,
    @Param() { uploadId }: AssetMediaUploadParamDto,
    @Body() dto: AssetMediaCreateDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AssetMediaResponseDto> {
    const responseDto = await this.service.finalizeChunkedUpload(auth, uploadId, dto);

    if (responseDto.status === AssetMediaStatus.DUPLICATE) {
      res.status(HttpStatus.OK);
    }

    return responseDto;
  }

  @Delete('upload/:uploadId')
  @Authenticated({ permission: Permission.AssetUpload, sharedLink: true })
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiResponse({ status: 204, description: 'Chunked upload deleted' })
  @Endpoint({
    summary: 'Delete a chunked upload',
    description: 'Aborts a chunked upload session and deletes any partial data.',
    history: new HistoryBuilder().added('v3.1.0').beta('v3.1.0'),
  })
  deleteChunkedUpload(@Auth() auth: AuthDto, @Param() { uploadId }: AssetMediaUploadParamDto): Promise<void> {
    return this.service.deleteChunkedUpload(auth, uploadId);
  }

  @Get(':id/original')
  @FileResponse()
  @Authenticated({ permission: Permission.AssetDownload, sharedLink: true })
  @Endpoint({
    summary: 'Download original asset',
    description: 'Downloads the original file of the specified asset.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  async downloadAsset(
    @Auth() auth: AuthDto,
    @Param() { id }: UUIDParamDto,
    @Query() dto: AssetDownloadOriginalDto,
    @Res() res: Response,
    @Next() next: NextFunction,
  ) {
    await sendFile(res, next, () => this.service.downloadOriginal(auth, id, dto), this.logger);
  }

  @Get(':id/thumbnail')
  @FileResponse()
  @Authenticated({ permission: Permission.AssetView, sharedLink: true })
  @Endpoint({
    summary: 'View asset thumbnail',
    description:
      'Retrieve the thumbnail image for the specified asset. Viewing the fullsize thumbnail might redirect to downloadAsset, which requires a different permission.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  async viewAsset(
    @Auth() auth: AuthDto,
    @Param() { id }: UUIDParamDto,
    @Query() dto: AssetMediaOptionsDto,
    @Req() req: Request,
    @Res() res: Response,
    @Next() next: NextFunction,
  ) {
    if (dto.size === AssetMediaSize.Original) {
      this.logger.deprecate(
        'Calling the thumbnail endpoint with size=original is deprecated. Use the :id/original endpoint instead',
      );
      const [_, reqSearch] = req.url.split('?', 2);
      const redirSearchParams = new URLSearchParams(reqSearch);
      redirSearchParams.delete('size');
      return res.redirect('original?' + redirSearchParams.toString());
    }

    const viewThumbnailRes = await this.service.viewThumbnail(auth, id, dto);

    if (viewThumbnailRes instanceof ImmichFileResponse) {
      await sendFile(res, next, () => Promise.resolve(viewThumbnailRes), this.logger);
    } else {
      // viewThumbnailRes is a AssetMediaRedirectResponse
      // which redirects to the original asset or a specific size to make better use of caching
      const { targetSize } = viewThumbnailRes;
      const [reqPath, reqSearch] = req.url.split('?', 2);
      let redirPath: string;
      const redirSearchParams = new URLSearchParams(reqSearch);
      if (targetSize === 'original') {
        // relative path to this.downloadAsset
        redirPath = 'original';
        redirSearchParams.delete('size');
      } else if (Object.values(AssetMediaSize).includes(targetSize)) {
        redirPath = reqPath;
        redirSearchParams.set('size', targetSize);
      } else {
        throw new Error('Invalid targetSize: ' + targetSize);
      }
      const finalRedirPath = redirPath + '?' + redirSearchParams.toString();
      return res.redirect(finalRedirPath);
    }
  }

  @Get(':id/video/playback')
  @FileResponse()
  @Authenticated({ permission: Permission.AssetView, sharedLink: true })
  @Endpoint({
    summary: 'Play asset video',
    description: 'Streams the video file for the specified asset. This endpoint also supports byte range requests.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  async playAssetVideo(
    @Auth() auth: AuthDto,
    @Param() { id }: UUIDParamDto,
    @Res() res: Response,
    @Next() next: NextFunction,
  ) {
    await sendFile(res, next, () => this.service.playbackVideo(auth, id), this.logger);
  }

  @Post('bulk-upload-check')
  @Authenticated({ permission: Permission.AssetUpload })
  @Endpoint({
    summary: 'Check bulk upload',
    description: 'Determine which assets have already been uploaded to the server based on their SHA1 checksums.',
    history: new HistoryBuilder().added('v1').beta('v1').stable('v2'),
  })
  @HttpCode(HttpStatus.OK)
  checkBulkUpload(
    @Auth() auth: AuthDto,
    @Body() dto: AssetBulkUploadCheckDto,
  ): Promise<AssetBulkUploadCheckResponseDto> {
    return this.service.bulkUploadCheck(auth, dto);
  }
}
