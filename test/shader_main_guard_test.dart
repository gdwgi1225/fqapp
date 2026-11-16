import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 固化 Windows Shader Warning 修复（third_party/liquid_glass_easy/PATCHES.md
/// 的「multi-return guard」条目）。
///
/// Flutter 的 Windows shader 编译器（impellerc --sksl）在 `main()` 同时使用
/// texture sampler 和多个 `return` 时，会在 stderr 打出「Fragment shader uses
/// texture samplers alongside multiple 'return' statements in main()」，构建
/// 日志里被包成方框 Shader Warning。修复把 main 主体抽进 `renderXxx()` 辅助
/// 函数：`main()` 只剩一行 `frag_color = renderXxx();`，函数体内零 `return`。
///
/// 若日后有人把分支逻辑写回 main 里加 return（或对 frag_color 多次赋值），
/// Windows 构建会重新冒出警告且无人拦截。本测试静态钉住这条约束。
void main() {
  // 相对包根目录；flutter test 的工作目录即包根。
  const shaderDir = 'third_party/liquid_glass_easy/lib/assets/shaders';
  // 只测三个自带 `void main()` 的入口 .frag；*_skia/_desktop/_unlit 变体通过
  // #include 复用主文件，本身不含 main。
  const entryFiles = [
    'liquid_glass.frag',
    'liquid_glass_border.frag',
    'metaball_glass.frag',
  ];

  // 去掉 // 行注释与 /* */ 块注释，避免注释里的花括号 / 关键字干扰计数。
  String stripComments(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      final next = i + 1 < src.length ? src[i + 1] : '';
      if (c == '/' && next == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
      } else if (c == '/' && next == '*') {
        i += 2;
        while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i += 2;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  // 取 `void main()` 的花括号函数体（不含最外层大括号本身）。
  String mainBody(String src, String file) {
    final stripped = stripComments(src);
    final match = RegExp(r'\bvoid\s+main\s*\(\s*\)').firstMatch(stripped);
    expect(match, isNotNull, reason: '$file 里找不到 void main()');
    final open = stripped.indexOf('{', match!.end);
    expect(open, isNot(-1), reason: '$file 的 main() 没有函数体');
    var depth = 0;
    for (var i = open; i < stripped.length; i++) {
      final ch = stripped[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return stripped.substring(open + 1, i);
      }
    }
    fail('$file 的 main() 大括号未闭合');
  }

  for (final file in entryFiles) {
    test('$file keeps a single-return main()', () {
      final f = File('$shaderDir/$file');
      expect(f.existsSync(), isTrue, reason: '找不到 $file（相对包根目录）');
      final body = mainBody(f.readAsStringSync(), file);
      final returns = RegExp(r'\breturn\b').allMatches(body).length;
      final assigns = RegExp(r'\bfrag_color\s*=').allMatches(body).length;
      expect(
        returns,
        0,
        reason: '$file 的 main() 里出现 return，会重新触发 Windows Shader Warning',
      );
      expect(assigns, 1, reason: r'$file 的 main() 应只对 frag_color 赋值一次');
    });
  }
}
