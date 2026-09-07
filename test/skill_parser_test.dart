import 'package:flutter_test/flutter_test.dart';

import 'package:qinglong_flutter/features/ai/skills/skill_parser.dart';

void main() {
  group('SkillParser.parse', () {
    test('解析标准 Agent Skills frontmatter', () {
      const raw = '''
---
name: pdf
description: Use this skill for PDF files
license: MIT
metadata:
  when_to_use: 用户要处理 PDF 时
---

# PDF Guide

正文内容
''';
      final doc = SkillParser.parse(raw);
      expect(doc.name, 'pdf');
      expect(doc.description, 'Use this skill for PDF files');
      expect(doc.license, 'MIT');
      expect(doc.whenToUse, '用户要处理 PDF 时');
      expect(doc.instructions, contains('# PDF Guide'));
      expect(doc.instructions, contains('正文内容'));
    });

    test('没有 frontmatter 时整份当正文并尽量猜名字', () {
      const raw = '''
# My Awesome Skill

Do something useful.
''';
      final doc = SkillParser.parse(raw);
      expect(doc.name, 'my-awesome-skill');
      expect(doc.description, 'Do something useful.');
      expect(doc.instructions, contains('# My Awesome Skill'));
    });

    test('metadata 支持顶层拍平写法', () {
      const raw = '''
---
name: skill-x
description: X
metadata.when_to_use: 遇到 X 时
---

body
''';
      final doc = SkillParser.parse(raw);
      expect(doc.whenToUse, '遇到 X 时');
    });
  });
}