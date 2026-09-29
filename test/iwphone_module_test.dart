import 'package:flutter_test/flutter_test.dart';
import 'package:shell_manager/models/iwphone_module.dart';
import 'package:shell_manager/services/iwphone_service.dart';

void main() {
  group('IwphoneModule.fromJson (WebUI)', () {
    test('解析完整字段', () {
      final m = IwphoneModule.fromJson({
        'name': 'doze_aggressive',
        'title': 'IWPhone 息屏深度doze',
        'version': '1.2.0',
        'author': '社区',
        'description': '息屏进入深度doze省电',
        'running': true,
        'pid': 1234,
        'has_main': true,
      });

      expect(m.id, 'doze_aggressive');
      expect(m.title, 'IWPhone 息屏深度doze');
      expect(m.version, '1.2.0');
      expect(m.running, isTrue);
      expect(m.pid, 1234);
      expect(m.hasMain, isTrue);
    });

    test('缺字段时回退为安全默认', () {
      final m = IwphoneModule.fromJson({'name': 'no_meta'});
      expect(m.title, 'no_meta'); // 缺 PackageName 时回退为 id
      expect(m.version, '');
      expect(m.running, isFalse);
      expect(m.pid, isNull);
      expect(m.hasMain, isTrue); // 缺省视为有 main.sh
    });

    test('displayVersion 自动补 v 前缀', () {
      final withV = IwphoneModule.fromJson({'name': 'a', 'version': 'v3.1'});
      final noV = IwphoneModule.fromJson({'name': 'a', 'version': '3.1'});
      final empty = IwphoneModule.fromJson({'name': 'a'});
      expect(withV.displayVersion, 'v3.1');
      expect(noV.displayVersion, 'v3.1');
      expect(empty.displayVersion, '—');
    });

    test('title 空字符串回退为 id', () {
      final m = IwphoneModule.fromJson({'name': 'x', 'title': ''});
      expect(m.title, 'x');
    });
  });

  group('IwphoneModule.fromProp (sdcard 镜像)', () {
    test('标准 iwphone.prop 字段全部识别', () {
      const prop = '''
PackageName=深度doze
version=1.2.0
author=社区
description=息屏深度doze省电
''';
      final m = IwphoneModule.fromProp('doze_aggressive', prop);
      expect(m.id, 'doze_aggressive');
      expect(m.title, '深度doze');
      expect(m.version, '1.2.0');
      expect(m.author, '社区');
      expect(m.description, '息屏深度doze省电');
      expect(m.running, isFalse); // sdcard 镜像无法获知运行态
    });

    test('缺 PackageName 时回退为目录名', () {
      const prop = 'version=1.0\nauthor=me\n';
      final m = IwphoneModule.fromProp('plain', prop);
      expect(m.title, 'plain');
      expect(m.version, '1.0');
    });

    test('合法行识别（= 必须存在，等号左边非空）', () {
      const prop = '=orphan\nno=eqHere\n=justexeq\n';
      final m = IwphoneModule.fromProp('z', prop);
      // '=orphan' 没有 key 所以被丢弃; 'no=eqHere' 应该进入
      expect(m.version, ''); // 没有 version=
    });
  });

  group('IwphoneStatus.fromJson', () {
    test('解析嵌套 daemon / counts / config', () {
      final s = IwphoneStatus.fromJson({
        'ok': true,
        'daemon': {'running': true, 'pid': 4321},
        'counts': {'modules': 7, 'running': 2},
        'config': {
          'work_dir': '/data/local/tmp/iwphone/work',
          'log_dir': '/sdcard/iwphone/logs',
          'sdcard_dir': '/sdcard/iwphone',
        },
      });
      expect(s.daemonRunning, isTrue);
      expect(s.daemonPid, 4321);
      expect(s.moduleCount, 7);
      expect(s.runningCount, 2);
      expect(s.workDir, '/data/local/tmp/iwphone/work');
      expect(s.logDir, '/sdcard/iwphone/logs');
      expect(s.sdcardDir, '/sdcard/iwphone');
    });

    test('缺字段时降级为 0 / false / 空串', () {
      final s = IwphoneStatus.fromJson({'ok': true});
      expect(s.daemonRunning, isFalse);
      expect(s.daemonPid, isNull);
      expect(s.moduleCount, 0);
      expect(s.runningCount, 0);
      expect(s.workDir, '');
    });
  });

  group('IwphonePackage.fromJson', () {
    test('基本解析', () {
      final p = IwphonePackage.fromJson({
        'name': 'doze',
        'file': 'doze.iwp',
        'installed': true,
      });
      expect(p.name, 'doze');
      expect(p.file, 'doze.iwp');
      expect(p.installed, isTrue);
    });
  });

  group('parseModulesFromSdcardListing (parse helper)', () {
    test('按 === 分隔的 prop 文件字典 + dir 列表解析', () {
      final props = <String, String>{
        'work/a/iwphone.prop': 'PackageName=A模块\nversion=1.0\n',
        'work/b/iwphone.prop': 'PackageName=B模块\nversion=2.0\n',
      };
      const listing = '''
dir|work/a
dir|work/b
file|work/c.txt
''';
      final mods = IwphoneService.parseModulesFromSdcardListing(listing, props);
      expect(mods.length, 2);
      expect(mods.map((m) => m.title), ['A模块', 'B模块']);
    });

    test('prop 缺失的目录被忽略', () {
      const listing = 'dir|work/empty\n';
      final mods = IwphoneService.parseModulesFromSdcardListing(
        listing,
        const {},
      );
      expect(mods.isEmpty, isTrue);
    });
  });

  group('splitPropFiles', () {
    test('按 ===path=== 头拆出多段', () {
      const raw = '''
===work/a/iwphone.prop===
PackageName=A
version=1.0
===work/b/iwphone.prop===
PackageName=B
version=2.0
''';
      final result = IwphoneService.splitPropFiles(raw);
      expect(result.keys, ['work/a/iwphone.prop', 'work/b/iwphone.prop']);
      expect(result['work/a/iwphone.prop'], contains('PackageName=A'));
      expect(result['work/b/iwphone.prop'], contains('PackageName=B'));
    });

    test('空输入返回空字典', () {
      expect(IwphoneService.splitPropFiles(''), isEmpty);
    });

    test('无 === 头视为整段无归属', () {
      const raw = 'just plain text\nno markers here';
      expect(IwphoneService.splitPropFiles(raw), isEmpty);
    });
  });
}
