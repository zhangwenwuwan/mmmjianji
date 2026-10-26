import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/ui/account_edit_page.dart';
import 'package:jianji/ui/bucket_manage_page.dart';

/// 2026-10-26 用户要求把「默认图标」砍到最少：
/// 图标栏一堆 emoji 铺三行，找图标比想名字还慢。
///
/// 这两条清单是**常量**，测试直接钉住长度，谁再往上加图标要在这里过一遍。
void main() {
  group('默认图标清单', () {
    test('账户图标栏只留四个：微信 / 支付宝 / 银行卡 / 信用卡', () {
      expect(AccountEditPage.glyphs, ['💚', '🅰️', '🏦', '💳']);
      expect(AccountEditPage.glyphs.length, 4);
      expect(AccountEditPage.glyphs.toSet().length, 4,
          reason: '别放重复的图标');
    });

    test('新增分类的默认图标 4~5 个，不重复', () {
      expect(kBucketGlyphs.length, inInclusiveRange(4, 5));
      expect(kBucketGlyphs.toSet().length, kBucketGlyphs.length);
    });
  });
}
