import { createZodDto } from 'nestjs-zod';
import { HistoryBuilder } from 'src/decorators';
import { AssetMetadataUpsertItemSchema } from 'src/dtos/asset.dto';
import { ApiCustomExtension, AssetVisibilitySchema } from 'src/enum';
import { isoDatetimeToDate, JsonParsed, stringToBool } from 'src/validation';
import z from 'zod';

export enum AssetMediaSize {
  Original = 'original',
  /**
   * An full-sized image extracted/converted from non-web-friendly formats like RAW/HIF.
   * or otherwise the original image itself.
   */
  FULLSIZE = 'fullsize',
  PREVIEW = 'preview',
  THUMBNAIL = 'thumbnail',
}

const AssetMediaSizeSchema = z.enum(AssetMediaSize).describe('Asset media size').meta({ id: 'AssetMediaSize' });

const AssetMediaOptionsSchema = z
  .object({
    size: AssetMediaSizeSchema.optional().meta(
      new HistoryBuilder()
        .updated('v3', "Specifying 'original' is deprecated. Use the original endpoint directly instead")
        .getExtensions(),
    ),
    edited: stringToBool.default(false).optional().describe('Return edited asset if available'),
  })
  .meta({ id: 'AssetMediaOptionsDto' });

export enum UploadFieldName {
  ASSET_DATA = 'assetData',
  SIDECAR_DATA = 'sidecarData',
  PROFILE_DATA = 'file',
}

const AssetMediaBaseSchema = z.object({
  fileCreatedAt: isoDatetimeToDate.describe('File creation date'),
  fileModifiedAt: isoDatetimeToDate.describe('File modification date'),
  duration: z.coerce.number().int().min(0).optional().describe('Duration in milliseconds (for videos)'),
  filename: z.string().optional().describe('Filename'),
  /**
   * The properties below are added to correctly generate the API docs and client SDKs. Validation should be handled
   * in the controller. File parts never reach the request body, so they must be optional here
   */
  [UploadFieldName.ASSET_DATA]: z
    .any()
    .optional()
    .describe('Asset file data')
    .meta({ type: 'string', format: 'binary', [ApiCustomExtension.Required]: true }),
});

const AssetMediaCreateSchema = AssetMediaBaseSchema.extend({
  isFavorite: stringToBool.optional().describe('Mark as favorite'),
  visibility: AssetVisibilitySchema.optional(),
  livePhotoVideoId: z.uuidv4().optional().describe('Live photo video ID'),
  metadata: JsonParsed.pipe(z.array(AssetMetadataUpsertItemSchema)).optional().describe('Asset metadata items'),
  [UploadFieldName.SIDECAR_DATA]: z
    .any()
    .optional()
    .describe('Sidecar file data')
    .meta({ type: 'string', format: 'binary' }),
}).meta({ id: 'AssetMediaCreateDto' });

const AssetBulkUploadCheckItemSchema = z
  .object({
    id: z.string().describe('Client-side identifier echoed in the response to match results to inputs (e.g. filename)'),
    checksum: z.string().describe('Base64 or hex encoded SHA1 hash'),
  })
  .meta({ id: 'AssetBulkUploadCheckItem' });

const AssetBulkUploadCheckSchema = z
  .object({
    assets: z.array(AssetBulkUploadCheckItemSchema).describe('Assets to check'),
  })
  .meta({ id: 'AssetBulkUploadCheckDto' });

const AssetMediaUploadInitSchema = z
  .object({
    filename: z.string().describe('Filename of the asset'),
    totalSize: z.coerce.number().int().min(0).optional().describe('Total size of the asset in bytes'),
    chunkCount: z.number().int().positive().describe('Number of chunks in the upload'),
    chunkSize: z.number().int().positive().describe('Size of each chunk in bytes'),
    chunkHashes: z
      .array(z.string().regex(/^[0-9a-f]{64}$/))
      .min(1)
      .describe('SHA256 hash (hex) of each chunk'),
  })
  .meta({ id: 'AssetMediaUploadInitDto' });

const AssetMediaUploadParamSchema = z
  .object({
    uploadId: z.uuidv4().describe('Chunked upload session ID'),
  })
  .meta({ id: 'AssetMediaUploadParamDto' });

const AssetMediaUploadQuerySchema = z
  .object({
    offset: z.coerce.number().int().min(0).describe('Byte offset of the chunk'),
  })
  .meta({ id: 'AssetMediaUploadQueryDto' });

export class AssetMediaOptionsDto extends createZodDto(AssetMediaOptionsSchema) {}
export class AssetMediaCreateDto extends createZodDto(AssetMediaCreateSchema) {}
export class AssetBulkUploadCheckDto extends createZodDto(AssetBulkUploadCheckSchema) {}
export class AssetMediaUploadInitDto extends createZodDto(AssetMediaUploadInitSchema) {}
export class AssetMediaUploadParamDto extends createZodDto(AssetMediaUploadParamSchema) {}
export class AssetMediaUploadQueryDto extends createZodDto(AssetMediaUploadQuerySchema) {}
