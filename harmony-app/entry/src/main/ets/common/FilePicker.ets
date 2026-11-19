// common/FilePicker.ets - pick a media file and stage it in the sandbox.
//
// The native engine works on plain file paths, while the picker hands out
// content URIs. The file is therefore copied into the application sandbox
// first, which also keeps the permission window short.
//
// The output of a conversion lands in the sandbox as well; the pages show the
// full path so the user can find it.

import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'MsVerify';

/** The name of a content URI, without directories. */
function uriName(uri: string): string {
  const cut = uri.lastIndexOf('/');
  let name = cut >= 0 ? uri.substring(cut + 1) : uri;
  // "file://media/Photo/IMG_1.2.3.jpg" may carry a query part.
  const q = name.indexOf('?');
  if (q > 0) {
    name = name.substring(0, q);
  }
  return name.length > 0 ? name : 'input';
}

/**
 * Opens the document picker and copies the chosen file into the sandbox.
 * Returns the sandbox path, or an empty string when the user cancels.
 */
export async function pickAndStage(ctx: common.UIAbilityContext,
  suffixFilter: string[]): Promise<string> {
  try {
    const documentPicker = new picker.DocumentViewPicker();
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 1,
      fileSuffixFilters: suffixFilter
    };
    const uris = await documentPicker.select(options);
    if (!uris || uris.length === 0) {
      return '';
    }
    const uri = uris[0];

    const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    let data: ArrayBuffer;
    try {
      const stat = fileIo.statSync(src.fd);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(src.fd, buffer);
      data = buffer;
    } finally {
      fileIo.closeSync(src.fd);
    }

    const target = ctx.filesDir + '/' + uriName(uri);
    const dst = fileIo.openSync(target,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(dst.fd, data);
    } finally {
      fileIo.closeSync(dst.fd);
    }
    hilog.info(0x3200, TAG, 'staged %{public}s -> %{public}s', uri, target);
    return target;
  } catch (e) {
    hilog.error(0x3200, TAG, 'pick failed: %{public}s', JSON.stringify(e));
    return '';
  }
}

/** Where a conversion writes its result. */
export function outputPath(ctx: common.UIAbilityContext, name: string): string {
  return ctx.filesDir + '/' + name;
}
