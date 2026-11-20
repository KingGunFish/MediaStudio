// common/Privacy.ets - 隐私同意状态的落盘与查询.
//
// 上架要求：首次启动必须弹出隐私声明，用户同意前不得使用应用；
// 同意状态必须持久化，隐私政策版本变化时要重新征求同意。
//
// 这里只落盘一条「同意 + 政策版本号」，不含任何个人信息；
// 数据落在应用沙箱内，卸载应用即随之清除。

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'MsVerify';

/** Preferences 实例名。 */
const STORE: string = 'ms_privacy';
/** 同意记录键。 */
const KEY_CONSENT: string = 'consent';

/**
 * 隐私政策版本号。
 *
 * 隐私政策内容发生实质性变更时必须 +1：记录里的版本与当前版本对不上
 * 就按「未同意」处理，已同意过的用户会再次看到首启弹窗。
 */
export const PRIVACY_VERSION: string = 'v1';

/**
 * 读取当前的同意状态。只有落盘版本号与当前版本完全一致才算已同意。
 * 读取失败一律按「未同意」处理 —— 宁可多弹一次弹窗，也不能默认放行。
 */
export async function isAccepted(ctx: common.UIAbilityContext): Promise<boolean> {
  try {
    const pref = await preferences.getPreferences(ctx, { name: STORE });
    const value = await pref.get(KEY_CONSENT, '') as string;
    return value === PRIVACY_VERSION;
  } catch (e) {
    hilog.error(0x3200, TAG, 'read consent failed: %{public}s', JSON.stringify(e));
    return false;
  }
}

/** 记录用户已同意当前版本的隐私政策。 */
export async function accept(ctx: common.UIAbilityContext): Promise<void> {
  try {
    const pref = await preferences.getPreferences(ctx, { name: STORE });
    await pref.put(KEY_CONSENT, PRIVACY_VERSION);
    await pref.flush();
    hilog.info(0x3200, TAG, 'privacy consent recorded: %{public}s', PRIVACY_VERSION);
  } catch (e) {
    hilog.error(0x3200, TAG, 'write consent failed: %{public}s', JSON.stringify(e));
  }
}

/** 撤回同意：删掉记录，下次启动会重新征求同意。 */
export async function revoke(ctx: common.UIAbilityContext): Promise<void> {
  try {
    const pref = await preferences.getPreferences(ctx, { name: STORE });
    await pref.delete(KEY_CONSENT);
    await pref.flush();
    hilog.info(0x3200, TAG, 'privacy consent revoked');
  } catch (e) {
    hilog.error(0x3200, TAG, 'revoke consent failed: %{public}s', JSON.stringify(e));
  }
}
