class LogItem {
  const LogItem(
      {this.id, this.dir = '', this.file = '', this.lines = const []});

  final String? id;
  final String dir;
  final String file;
  final List<String> lines;
}
