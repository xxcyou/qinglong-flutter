import 'package:markdown/markdown.dart' as md;

List<md.Node> _parseInner(md.InlineParser parser, String text) {
  return md.InlineParser(text, parser.document).parse();
}

class UnderlineSyntax extends md.InlineSyntax {
  UnderlineSyntax() : super(r'\+\+(.+?)\+\+');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('u', _parseInner(parser, match.group(1) ?? '')));
    return true;
  }
}

class GlowSyntax extends md.InlineSyntax {
  GlowSyntax() : super(r'==(.+?)==');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('mark', _parseInner(parser, match.group(1) ?? '')));
    return true;
  }
}

class ColorSyntax extends md.InlineSyntax {
  ColorSyntax() : super(r'\{c:([^}\n]+)\}(.+?)\{/c\}');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('span', _parseInner(parser, match.group(2) ?? ''))
      ..attributes['color'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

class HighlightSyntax extends md.InlineSyntax {
  HighlightSyntax() : super(r'\{bg:([^}\n]+)\}(.+?)\{/bg\}');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('highlight', _parseInner(parser, match.group(2) ?? ''))
      ..attributes['bg'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

void dump(List<md.Node> nodes, [int indent = 0]) {
  final pad = '  ' * indent;
  for (final n in nodes) {
    if (n is md.Text) {
      print('${pad}Text("${n.text}")');
    } else if (n is md.Element) {
      print('${pad}Element<${n.tag}> ${n.attributes}');
      dump(n.children ?? const [], indent + 1);
    } else {
      print('${pad}${n.runtimeType}');
    }
  }
}

void main() {
  final ext = md.ExtensionSet(
    md.ExtensionSet.gitHubFlavored.blockSyntaxes,
    [
      ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
      UnderlineSyntax(),
      GlowSyntax(),
      ColorSyntax(),
      HighlightSyntax(),
    ],
  );
  final samples = [
    '=={c:green}4 个在跑{/c}==',
    '{c:red}{bg:yellow}==**~~关键~~**=={/bg}{/c}',
    '==**~~text~~**==',
    '{c:red}{bg:yellow}{c:blue}text{/c}{/bg}{/c}',
  ];
  for (final s in samples) {
    print('--- $s');
    final doc = md.Document(extensionSet: ext);
    dump(doc.parseInline(s));
  }
}
