part of 'pr_check.dart';

/// Classification of a newly exported public symbol in a package entrypoint.
enum PublicSymbolKind { topLevel, extensionMember }

/// A public top-level symbol or extension member added to [entrypoint].
final class AddedPublicSymbol {
  final String entrypoint;
  final String name;
  final PublicSymbolKind kind;
  final String? enclosingExtension;

  const new({
    required this.entrypoint,
    required this.name,
    required this.kind,
    this.enclosingExtension,
  });

  @override
  bool operator ==(Object other) =>
      other is AddedPublicSymbol &&
      other.entrypoint == entrypoint &&
      other.name == name &&
      other.kind == kind &&
      other.enclosingExtension == enclosingExtension;

  @override
  int get hashCode => Object.hash(entrypoint, name, kind, enclosingExtension);

  @override
  String toString() => kind == PublicSymbolKind.extensionMember
      ? '$entrypoint:${enclosingExtension ?? '<ext>'}.$name'
      : '$entrypoint:$name';
}

/// Snapshot of a published reverse-dependency package's `lib/` Dart sources.
final class ReverseDepConsumer {
  final String name;
  final String version;
  final Map<String, String> libDartFiles;

  const new({
    required this.name,
    required this.version,
    required this.libDartFiles,
  });
}

/// A symbol collision between a newly added public API and a published
/// downstream consumer.
final class ReverseDepCollision {
  final String consumerName;
  final String consumerVersion;
  final String filePath;
  final AddedPublicSymbol symbol;

  const new({
    required this.consumerName,
    required this.consumerVersion,
    required this.filePath,
    required this.symbol,
  });

  String get formattedSummary {
    final symLabel = symbol.kind == PublicSymbolKind.extensionMember
        ? '${symbol.enclosingExtension ?? 'extension'}.${symbol.name}'
        : symbol.name;
    return '$consumerName@$consumerVersion ($filePath) already declares '
        '`$symLabel` while importing `${symbol.entrypoint}`';
  }
}

/// Callback that returns published downstream consumers of [packageName] whose
/// version constraint admits [targetReleaseVersion].
typedef ReverseDepLookup = List<ReverseDepConsumer> Function(
  String packageName,
  Version targetReleaseVersion,
);

final _apiTxtLibraryHeaderRegex = RegExp(r'^(package:[^:\s]+):$');
final _apiTxtTopLevelDeclRegex = RegExp(
  r'^  ([A-Za-z_$][A-Za-z0-9_$]*)\s+\((.+)\):?$',
);
final _apiTxtMemberDeclRegex = RegExp(
  r'^    ([A-Za-z_$][A-Za-z0-9_$]*)\s+\((getter|setter|method|operator):',
);

/// Extracts public top-level declarations and extension members belonging to
/// [packageName] from `package:api_summary` `api.txt` content.
Set<AddedPublicSymbol> parsePublicSymbolsFromApiTxt(
  String packageName,
  String apiTxtContent,
) {
  final symbols = <AddedPublicSymbol>{};
  final pkgPrefix = 'package:$packageName/';
  String? currentEntrypoint;
  String? currentExtension;

  for (final rawLine in const LineSplitter().convert(apiTxtContent)) {
    if (rawLine.isEmpty) continue;
    if (!rawLine.startsWith(' ')) {
      final uri = _apiTxtLibraryHeaderRegex.firstMatch(rawLine)?.group(1);
      currentEntrypoint = uri != null && uri.startsWith(pkgPrefix) ? uri : null;
      currentExtension = null;
      continue;
    }
    if (currentEntrypoint != null) {
      currentExtension = _parseApiTxtIndentedLine(
        rawLine: rawLine,
        entrypoint: currentEntrypoint,
        currentExtension: currentExtension,
        symbols: symbols,
      );
    }
  }
  return symbols;
}

String? _parseApiTxtIndentedLine({
  required String rawLine,
  required String entrypoint,
  required String? currentExtension,
  required Set<AddedPublicSymbol> symbols,
}) {
  final topMatch = _apiTxtTopLevelDeclRegex.firstMatch(rawLine);
  if (topMatch != null) {
    final name = topMatch.group(1)!;
    final kindDesc = topMatch.group(2)!;
    if (kindDesc == 'referenced') return null;
    symbols.add(
      AddedPublicSymbol(
        entrypoint: entrypoint,
        name: name,
        kind: PublicSymbolKind.topLevel,
      ),
    );
    final isExt =
        kindDesc == 'extension' || kindDesc.startsWith('extension on ');
    return isExt ? name : null;
  }

  if (currentExtension != null) {
    final memberName = _apiTxtMemberDeclRegex.firstMatch(rawLine)?.group(1);
    if (memberName != null) {
      symbols.add(
        AddedPublicSymbol(
          entrypoint: entrypoint,
          name: memberName,
          kind: PublicSymbolKind.extensionMember,
          enclosingExtension: currentExtension,
        ),
      );
    }
  }
  return currentExtension;
}

final _lineCommentRegex = RegExp(r'//[^\n]*');
final _blockCommentRegex = RegExp(r'/\*[\s\S]*?\*/');
final _topTypeDeclRegex = RegExp(
  r'^\s*(?:(?:abstract|base|final|interface|sealed|inline|augment)\s+)*'
  r'(?:class|enum|mixin|typedef|extension(?:\s+type)?)\s+'
  r'([A-Za-z_$][A-Za-z0-9_$]*)',
  multiLine: true,
);
final _topFuncOrVarDeclRegex = RegExp(
  r'^(?!(?:import|export|part|library|class|enum|mixin|typedef|extension)\b)'
  r'(?:external[ \t]+)?(?:const[ \t]+|final[ \t]+|var[ \t]+|late[ \t]+)*'
  r'(?:[A-Za-z_$][^\n(=;{\x27"]*?[ \t]+)?(?:get[ \t]+|set[ \t]+)?'
  r'([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*(?:<[^\n>]+>)?[ \t]*(?:\(|=>|=|;)',
  multiLine: true,
);
final _extensionHeaderRegex = RegExp(
  r'^[ \t]*extension(?:[ \t]+([A-Za-z_$][A-Za-z0-9_$]*))?(?:[ \t]*<[^\n>]+>)?'
  r'[ \t]+on[ \t]+[^{\n]+\{',
  multiLine: true,
);
final _extensionMemberDeclRegex = RegExp(
  r'^[ \t]{2,4}(?:static[ \t]+)?(?:[A-Za-z_$][^\n(=;{]*?[ \t]+)?'
  r'(?:get[ \t]+|set[ \t]+)?([A-Za-z_$][A-Za-z0-9_$]*)'
  r'[ \t]*(?:<[^\n>]+>)?[ \t]*(?:\(|=>|\{)',
  multiLine: true,
);
final _exportDirectiveRegex = RegExp(
  r'''^\s*export\s+['"]([^'"]+)['"]([^;]*);''',
  multiLine: true,
);

const _dartKeywords = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

final class _ParsedDartFile {
  final Set<String> publicTopLevel = {};
  final Map<String, Set<String>> publicExtensionMembers = {};
  final List<({String uri, Set<String>? showNames, Set<String> hideNames})>
  exports = [];
}

String _stripDartComments(String source) =>
    source.replaceAll(_blockCommentRegex, '').replaceAll(_lineCommentRegex, '');

bool _isPublicDartIdentifier(String name) =>
    !name.startsWith('_') && !_dartKeywords.contains(name);

void _addPublicMatches(RegExp pattern, String source, Set<String> target) {
  for (final m in pattern.allMatches(source)) {
    final name = m.group(1)!;
    if (_isPublicDartIdentifier(name)) target.add(name);
  }
}

_ParsedDartFile _parseDartSourceFile(String rawSource) {
  final clean = _stripDartComments(rawSource);
  final parsed = _ParsedDartFile();

  _addPublicMatches(_topTypeDeclRegex, clean, parsed.publicTopLevel);
  _addPublicMatches(_topFuncOrVarDeclRegex, clean, parsed.publicTopLevel);

  for (final extMatch in _extensionHeaderRegex.allMatches(clean)) {
    final extName = extMatch.group(1) ?? '<unnamed>';
    if (extName.startsWith('_')) continue;
    final body = _extractBraceBody(clean, extMatch.end - 1);
    if (body == null) continue;
    final members = parsed.publicExtensionMembers.putIfAbsent(
      extName,
      () => <String>{},
    );
    _addPublicMatches(_extensionMemberDeclRegex, body, members);
  }
  for (final expMatch in _exportDirectiveRegex.allMatches(clean)) {
    final uri = expMatch.group(1)!;
    final combinators = expMatch.group(2) ?? '';
    final (:showNames, :hideNames) = _parseCombinators(combinators);
    parsed.exports.add((uri: uri, showNames: showNames, hideNames: hideNames));
  }
  return parsed;
}

String? _extractBraceBody(String source, int openBraceIndex) {
  var depth = 0;
  for (var i = openBraceIndex; i < source.length; i++) {
    final ch = source.codeUnitAt(i);
    if (ch == 0x7B) {
      depth++;
    } else if (ch == 0x7D) {
      depth--;
      if (depth == 0) {
        return source.substring(openBraceIndex + 1, i);
      }
    }
  }
  return null;
}

({Set<String>? showNames, Set<String> hideNames}) _parseCombinators(
  String clause,
) {
  Set<String>? showNames;
  final hideNames = <String>{};
  final tokenRegex = RegExp(
    r'\b(show|hide)\s+([A-Za-z0-9_$,\s]+?)(?=\b(?:show|hide|deferred|as)\b|$)',
  );
  for (final m in tokenRegex.allMatches(clause)) {
    final kind = m.group(1)!;
    final names = m
        .group(2)!
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    if (kind == 'show') {
      (showNames ??= <String>{}).addAll(names);
    } else {
      hideNames.addAll(names);
    }
  }
  return (showNames: showNames, hideNames: hideNames);
}

/// Extracts public symbols exported by non-`src/` entrypoints in [libFiles]
/// (keyed by package-relative path such as `lib/foo.dart` or
/// `lib/src/bar.dart`).
Set<AddedPublicSymbol> parsePublicSymbolsFromLibFiles(
  String packageName,
  Map<String, String> libFiles,
) {
  final parsedByPath = <String, _ParsedDartFile>{
    for (final MapEntry(:key, :value) in libFiles.entries)
      p.posix.normalize(key): _parseDartSourceFile(value),
  };
  final symbols = <AddedPublicSymbol>{};
  for (final filePath in parsedByPath.keys) {
    if (!filePath.startsWith('lib/') || filePath.startsWith('lib/src/')) {
      continue;
    }
    final relUnderLib = filePath.substring('lib/'.length);
    final entrypoint = 'package:$packageName/$relUnderLib';
    _collectExportedSymbols(
      entrypoint: entrypoint,
      packageName: packageName,
      currentPath: filePath,
      parsedByPath: parsedByPath,
      visitedPaths: <String>{},
      showFilter: null,
      hideFilter: const <String>{},
      out: symbols,
    );
  }
  return symbols;
}

void _collectExportedSymbols({
  required String entrypoint,
  required String packageName,
  required String currentPath,
  required Map<String, _ParsedDartFile> parsedByPath,
  required Set<String> visitedPaths,
  required Set<String>? showFilter,
  required Set<String> hideFilter,
  required Set<AddedPublicSymbol> out,
}) {
  if (!visitedPaths.add(currentPath)) return;
  final parsed = parsedByPath[currentPath];
  if (parsed == null) return;

  _addFilteredParsedSymbols(
    entrypoint: entrypoint,
    parsed: parsed,
    showFilter: showFilter,
    hideFilter: hideFilter,
    out: out,
  );
  for (final exp in parsed.exports) {
    final targetPath = _resolveIntraPackagePath(
      packageName,
      currentPath,
      exp.uri,
    );
    if (targetPath == null) continue;
    _collectExportedSymbols(
      entrypoint: entrypoint,
      packageName: packageName,
      currentPath: targetPath,
      parsedByPath: parsedByPath,
      visitedPaths: visitedPaths,
      showFilter: _mergeShowFilters(showFilter, exp.showNames),
      hideFilter: <String>{...hideFilter, ...exp.hideNames},
      out: out,
    );
  }
}

void _addFilteredParsedSymbols({
  required String entrypoint,
  required _ParsedDartFile parsed,
  required Set<String>? showFilter,
  required Set<String> hideFilter,
  required Set<AddedPublicSymbol> out,
}) {
  bool allowsName(String name) =>
      !hideFilter.contains(name) &&
      (showFilter == null || showFilter.contains(name));

  for (final topName in parsed.publicTopLevel.where(allowsName)) {
    out.add(
      AddedPublicSymbol(
        entrypoint: entrypoint,
        name: topName,
        kind: PublicSymbolKind.topLevel,
      ),
    );
  }
  for (final MapEntry(key: extName, value: members)
      in parsed.publicExtensionMembers.entries) {
    if (extName != '<unnamed>' && !allowsName(extName)) continue;
    final enclosing = extName == '<unnamed>' ? null : extName;
    for (final member in members) {
      out.add(
        AddedPublicSymbol(
          entrypoint: entrypoint,
          name: member,
          kind: PublicSymbolKind.extensionMember,
          enclosingExtension: enclosing,
        ),
      );
    }
  }
}

String? _resolveIntraPackagePath(
  String packageName,
  String fromPath,
  String uri,
) {
  final pkgPrefix = 'package:$packageName/';
  if (uri.startsWith(pkgPrefix)) {
    return p.posix.normalize('lib/${uri.substring(pkgPrefix.length)}');
  }
  if (uri.contains(':')) return null;
  return p.posix.normalize(p.posix.join(p.posix.dirname(fromPath), uri));
}

Set<String>? _mergeShowFilters(Set<String>? outer, Set<String>? inner) {
  if (outer == null) return inner;
  if (inner == null) return outer;
  return outer.intersection(inner);
}

/// Checks whether any [consumers] declare top-level symbols or extension
/// members that collide with [addedSymbols] while importing the corresponding
/// package entrypoint without a guarding `show`/`hide` clause.
List<ReverseDepCollision> findReverseDepApiCollisions(
  Iterable<AddedPublicSymbol> addedSymbols,
  Iterable<ReverseDepConsumer> consumers,
) {
  final addedList = addedSymbols.toList();
  if (addedList.isEmpty) return const [];
  final collisions = <ReverseDepCollision>[];
  for (final consumer in consumers) {
    collisions.addAll(_findSingleConsumerCollisions(consumer, addedList));
  }
  return collisions;
}

List<ReverseDepCollision> _findSingleConsumerCollisions(
  ReverseDepConsumer consumer,
  List<AddedPublicSymbol> addedSymbols,
) {
  final parsedFiles = <String, ({String clean, _ParsedDartFile decls})>{
    for (final MapEntry(:key, :value) in consumer.libDartFiles.entries)
      key: (
        clean: _stripDartComments(value),
        decls: _parseDartSourceFile(value),
      ),
  };
  final collisions = <ReverseDepCollision>[];
  for (final sym in addedSymbols) {
    final hasUnguardedImport = parsedFiles.values.any(
      (f) => _fileImportsSymbolUnguarded(f.clean, sym),
    );
    if (!hasUnguardedImport) continue;

    for (final MapEntry(key: filePath, value: fileData)
        in parsedFiles.entries) {
      if (_fileDeclaresCollidingSymbol(fileData.decls, sym)) {
        collisions.add(
          ReverseDepCollision(
            consumerName: consumer.name,
            consumerVersion: consumer.version,
            filePath: filePath,
            symbol: sym,
          ),
        );
      }
    }
  }
  return collisions;
}

bool _fileImportsSymbolUnguarded(String cleanSource, AddedPublicSymbol sym) {
  final pattern = RegExp(
    '''(?:^|\\n)\\s*import\\s+['"]${RegExp.escape(sym.entrypoint)}['"]([^;]*);''',
  );
  for (final m in pattern.allMatches(cleanSource)) {
    final clause = m.group(1) ?? '';
    final (:showNames, :hideNames) = _parseCombinators(clause);
    if (sym.kind == PublicSymbolKind.topLevel) {
      final hasPrefix = RegExp(r'\bas\s+[A-Za-z_$]').hasMatch(clause);
      if (!hasPrefix && showNames == null && !hideNames.contains(sym.name)) {
        return true;
      }
    } else {
      final extName = sym.enclosingExtension;
      final hidden = extName != null && hideNames.contains(extName);
      final shown =
          showNames == null || (extName != null && showNames.contains(extName));
      if (!hidden && shown) return true;
    }
  }
  return false;
}

bool _fileDeclaresCollidingSymbol(
  _ParsedDartFile decls,
  AddedPublicSymbol sym,
) {
  if (sym.kind == PublicSymbolKind.topLevel) {
    return decls.publicTopLevel.contains(sym.name);
  }
  return decls.publicExtensionMembers.values.any(
    (members) => members.contains(sym.name),
  );
}

/// Discovers published reverse-dependency packages from `~/.pub-cache` (merged
/// with any [preFetchedConsumers] from `pub.dev`) whose `dependencies:`
/// constraint on [packageName] allows [targetReleaseVersion].
List<ReverseDepConsumer> discoverPublishedReverseDepConsumers(
  String packageName,
  Version targetReleaseVersion, {
  Directory? pubCacheHostedDir,
  Iterable<ReverseDepConsumer> preFetchedConsumers = const [],
}) {
  final byName = <String, ReverseDepConsumer>{
    for (final c in preFetchedConsumers) c.name: c,
  };
  final hostedDir = pubCacheHostedDir ?? _defaultPubCacheHostedDir();
  if (hostedDir == null || !hostedDir.existsSync()) {
    return byName.values.toList();
  }

  final latestDirByPkg = _collectLatestPubCacheDirs(
    hostedDir: hostedDir,
    excludedPackage: packageName,
    alreadyResolved: byName.keys.toSet(),
  );
  for (final MapEntry(key: name, value: (ver, dir)) in latestDirByPkg.entries) {
    if (!_pubspecDependsOnAllowedVersion(
      File(p.join(dir.path, 'pubspec.yaml')),
      packageName,
      targetReleaseVersion,
    )) {
      continue;
    }
    final libFiles = _readDirectoryLibDartFiles(dir);
    if (libFiles.isNotEmpty) {
      byName[name] = ReverseDepConsumer(
        name: name,
        version: ver.toString(),
        libDartFiles: libFiles,
      );
    }
  }
  return byName.values.toList();
}

Map<String, (Version, Directory)> _collectLatestPubCacheDirs({
  required Directory hostedDir,
  required String excludedPackage,
  required Set<String> alreadyResolved,
}) {
  final latestDirByPkg = <String, (Version, Directory)>{};
  final dirNameRegex = RegExp(r'^([a-z0-9_]+)-(\d+\.\d+\.\d+.*)$');
  for (final entity in hostedDir.listSync().whereType<Directory>()) {
    final match = dirNameRegex.firstMatch(p.basename(entity.path));
    if (match == null) continue;
    final name = match.group(1)!;
    if (name == excludedPackage || alreadyResolved.contains(name)) continue;
    final ver = _tryParseStableVersion(match.group(2)!);
    if (ver == null) continue;
    final prev = latestDirByPkg[name];
    if (prev == null || ver > prev.$1) {
      latestDirByPkg[name] = (ver, entity);
    }
  }
  return latestDirByPkg;
}

Version? _tryParseStableVersion(String raw) {
  try {
    final ver = Version.parse(raw);
    return ver.isPreRelease ? null : ver;
  } on FormatException {
    return null;
  }
}

Directory? _defaultPubCacheHostedDir() {
  final pubCache =
      Platform.environment['PUB_CACHE'] ??
      (Platform.environment['HOME'] != null
          ? p.join(Platform.environment['HOME']!, '.pub-cache')
          : null);
  if (pubCache == null) return null;
  return Directory(p.join(pubCache, 'hosted', 'pub.dev'));
}

bool _pubspecDependsOnAllowedVersion(
  File pubspecFile,
  String dependencyName,
  Version targetReleaseVersion,
) {
  if (!pubspecFile.existsSync()) return false;
  try {
    return pubspecContentAllowsDependencyVersion(
      pubspecFile.readAsStringSync(),
      dependencyName,
      targetReleaseVersion,
    );
  } on Object {
    return false;
  }
}

/// Returns `true` if `pubspec.yaml` content [pubspecYaml] declares a direct
/// `dependencies:` entry on [dependencyName] whose constraint allows
/// [targetReleaseVersion].
bool pubspecContentAllowsDependencyVersion(
  String pubspecYaml,
  String dependencyName,
  Version targetReleaseVersion,
) {
  try {
    final doc = loadYaml(pubspecYaml);
    if (doc is! YamlMap) return false;
    final deps = doc['dependencies'];
    if (deps is! YamlMap || !deps.containsKey(dependencyName)) return false;
    final rawConstraint = deps[dependencyName];
    if (rawConstraint == null) return true;
    if (rawConstraint is! String) return false;
    return VersionConstraint.parse(rawConstraint).allows(targetReleaseVersion);
  } on Object {
    return false;
  }
}

Map<String, String> _readDirectoryLibDartFiles(Directory pkgDir) {
  final libDir = Directory(p.join(pkgDir.path, 'lib'));
  if (!libDir.existsSync()) return const {};
  final files = <String, String>{};
  for (final file in libDir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final rel = p.posix.joinAll(
      p.split(p.relative(file.path, from: pkgDir.path)),
    );
    files[rel] = file.readAsStringSync();
  }
  return files;
}

/// Extracts `lib/**.dart` files from a `.tar.gz` package archive in memory.
Map<String, String> extractLibDartFilesFromTarGz(List<int> tarGzBytes) {
  final tarBytes = gzip.decode(tarGzBytes);
  final files = <String, String>{};
  var offset = 0;
  String? gnuLongName;

  while (offset + 512 <= tarBytes.length) {
    final header = tarBytes.sublist(offset, offset + 512);
    if (header.every((b) => b == 0)) break;

    final size = _parseOctalTarField(header, 124, 12);
    final typeFlag = header[156] == 0 ? 0x30 : header[156];
    final dataStart = offset + 512;
    final nextHeader = dataStart + ((size + 511) ~/ 512) * 512;
    if (dataStart + size > tarBytes.length) break;

    if (typeFlag == 0x4C) {
      // GNU tar '././@LongLink' filename extension.
      gnuLongName = _decodeNullTerminatedUtf8(
        tarBytes.sublist(dataStart, dataStart + size),
      );
      offset = nextHeader;
      continue;
    }

    final rawName = gnuLongName ?? _readTarEntryPath(header);
    gnuLongName = null;
    final normalized = p.posix.normalize(rawName);
    if ((typeFlag == 0x30 || typeFlag == 0x00) &&
        normalized.startsWith('lib/') &&
        normalized.endsWith('.dart')) {
      files[normalized] = utf8.decode(
        tarBytes.sublist(dataStart, dataStart + size),
        allowMalformed: true,
      );
    }
    offset = nextHeader;
  }
  return files;
}

int _parseOctalTarField(List<int> header, int start, int length) {
  final text = _decodeNullTerminatedUtf8(header.sublist(start, start + length))
      .trim();
  return text.isEmpty ? 0 : (int.tryParse(text, radix: 8) ?? 0);
}

String _readTarEntryPath(List<int> header) {
  final name = _decodeNullTerminatedUtf8(header.sublist(0, 100));
  final prefix = _decodeNullTerminatedUtf8(header.sublist(345, 500));
  return prefix.isEmpty ? name : '$prefix/$name';
}

String _decodeNullTerminatedUtf8(List<int> bytes) {
  final zeroIdx = bytes.indexOf(0);
  final slice = zeroIdx >= 0 ? bytes.sublist(0, zeroIdx) : bytes;
  return utf8.decode(slice, allowMalformed: true);
}

/// Queries `pub.dev` for top reverse dependencies of [packageName] whose
/// latest published version constraint admits [targetReleaseVersion],
/// downloading and extracting their `lib/**.dart` files in memory.
Future<List<ReverseDepConsumer>> fetchPubDevReverseDepConsumers(
  String packageName,
  Version targetReleaseVersion, {
  Duration timeout = const Duration(seconds: 3),
  int maxPackages = 10,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final searchUri = Uri.https('pub.dev', '/api/search', {
      'q': 'dependency:$packageName',
    });
    final searchJson = await _getJsonMap(client, searchUri, timeout);
    final packages = searchJson?['packages'];
    if (packages is! List) return const [];

    final candidateNames = packages
        .whereType<Map<String, Object?>>()
        .map((m) => m['package'])
        .whereType<String>()
        .where((name) => name != packageName)
        .take(maxPackages)
        .toList();

    final fetched = await Future.wait(
      candidateNames.map(
        (consumerName) => _fetchSinglePubDevConsumer(
          client,
          consumerName,
          packageName,
          targetReleaseVersion,
          timeout,
        ),
      ),
    );
    return fetched.whereType<ReverseDepConsumer>().toList();
  } on Object {
    return const [];
  } finally {
    client.close(force: true);
  }
}

Future<ReverseDepConsumer?> _fetchSinglePubDevConsumer(
  HttpClient client,
  String consumerName,
  String dependencyName,
  Version targetReleaseVersion,
  Duration timeout,
) async {
  try {
    final metaUri = Uri.https('pub.dev', '/api/packages/$consumerName');
    final meta = await _getJsonMap(client, metaUri, timeout);
    final latest = meta?['latest'];
    if (latest is! Map<String, Object?>) return null;
    final ver = latest['version'];
    final archiveUrl = latest['archive_url'];
    final pubspec = latest['pubspec'];
    if (ver is! String ||
        archiveUrl is! String ||
        pubspec is! Map<String, Object?>) {
      return null;
    }
    final deps = pubspec['dependencies'];
    if (deps is! Map<String, Object?> || !deps.containsKey(dependencyName)) {
      return null;
    }
    final rawConstraint = deps[dependencyName];
    if (rawConstraint is String &&
        !VersionConstraint.parse(rawConstraint).allows(targetReleaseVersion)) {
      return null;
    }
    final req = await client.getUrl(Uri.parse(archiveUrl)).timeout(timeout);
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != HttpStatus.ok) return null;
    final bytes = await resp.expand((chunk) => chunk).toList().timeout(timeout);
    return ReverseDepConsumer(
      name: consumerName,
      version: ver,
      libDartFiles: extractLibDartFilesFromTarGz(bytes),
    );
  } on Object {
    return null;
  }
}

Future<Map<String, Object?>?> _getJsonMap(
  HttpClient client,
  Uri uri,
  Duration timeout,
) async {
  final req = await client.getUrl(uri).timeout(timeout);
  final resp = await req.close().timeout(timeout);
  if (resp.statusCode != HttpStatus.ok) return null;
  final body = await resp.transform(utf8.decoder).join().timeout(timeout);
  final decoded = jsonDecode(body);
  return decoded is Map<String, Object?> ? decoded : null;
}

/// Returns the target stable release [Version] if [currentVer] is within the
/// caret compatibility range of [baseVerStr] (`^baseVer`), or `null` if
/// [currentVer] is a major (or `0.y.z`-breaking) version bump.
Version? nonMajorTargetReleaseVersion(Version? currentVer, String? baseVerStr) {
  if (currentVer == null || baseVerStr == null) return null;
  try {
    final baseVer = Version.parse(baseVerStr);
    final baseRelease = Version(baseVer.major, baseVer.minor, baseVer.patch);
    final targetRelease = Version(
      currentVer.major,
      currentVer.minor,
      currentVer.patch,
    );
    if (!VersionConstraint.compatibleWith(baseRelease).allows(targetRelease)) {
      return null;
    }
    return targetRelease;
  } on FormatException {
    return null;
  }
}

/// Computes newly exported public top-level symbols and extension members in
/// [pkg] compared to [baseRef].
Set<AddedPublicSymbol> computePackageAddedPublicSymbols({
  required Directory repoRoot,
  required String baseRef,
  required firehose.Package pkg,
  required String prefix,
  required List<String> pkgChanged,
  required SyncProcessRunner runSync,
}) {
  if (!pkgChanged.any((f) => f == 'api.txt' || f.startsWith('lib/'))) {
    return const {};
  }
  final apiTxtFile = File(p.join(pkg.directory.path, 'api.txt'));
  if (apiTxtFile.existsSync()) {
    final baseApiRes = runSync('git', [
      'show',
      '$baseRef:${prefix}api.txt',
    ], workingDirectory: repoRoot.path);
    final baseApiTxt = baseApiRes.exitCode == 0
        ? (baseApiRes.stdout as String)
        : '';
    if (baseApiTxt.isNotEmpty) {
      final headSymbols = parsePublicSymbolsFromApiTxt(
        pkg.name,
        apiTxtFile.readAsStringSync(),
      );
      final baseSymbols = parsePublicSymbolsFromApiTxt(pkg.name, baseApiTxt);
      return headSymbols.difference(baseSymbols);
    }
  }

  final headLibFiles = _readDirectoryLibDartFiles(pkg.directory);
  if (headLibFiles.isEmpty) return const {};
  final baseLibFiles = _readBaseLibDartFiles(
    repoRoot: repoRoot,
    baseRef: baseRef,
    prefix: prefix,
    headLibFiles: headLibFiles,
    pkgChanged: pkgChanged.toSet(),
    runSync: runSync,
  );
  if (baseLibFiles.isEmpty) return const {};
  final headSymbols = parsePublicSymbolsFromLibFiles(pkg.name, headLibFiles);
  final baseSymbols = parsePublicSymbolsFromLibFiles(pkg.name, baseLibFiles);
  return headSymbols.difference(baseSymbols);
}

Map<String, String> _readBaseLibDartFiles({
  required Directory repoRoot,
  required String baseRef,
  required String prefix,
  required Map<String, String> headLibFiles,
  required Set<String> pkgChanged,
  required SyncProcessRunner runSync,
}) {
  final baseFiles = <String, String>{};
  for (final MapEntry(key: relPath, value: headContent)
      in headLibFiles.entries) {
    if (!pkgChanged.contains(relPath)) {
      baseFiles[relPath] = headContent;
      continue;
    }
    final res = runSync('git', [
      'show',
      '$baseRef:$prefix$relPath',
    ], workingDirectory: repoRoot.path);
    if (res.exitCode == 0) {
      final content = res.stdout as String;
      if (content.isNotEmpty) baseFiles[relPath] = content;
    }
  }
  return baseFiles;
}

PrCheckViolation? _checkPackageReverseDepCollisions({
  required Directory repoRoot,
  required String baseRef,
  required firehose.Package pkg,
  required String prefix,
  required List<String> pkgChanged,
  required String? baseVerStr,
  required SyncProcessRunner runSync,
  required ReverseDepLookup? reverseDepLookup,
}) {
  final targetRelease = nonMajorTargetReleaseVersion(pkg.version, baseVerStr);
  if (targetRelease == null) return null;

  final addedSymbols = computePackageAddedPublicSymbols(
    repoRoot: repoRoot,
    baseRef: baseRef,
    pkg: pkg,
    prefix: prefix,
    pkgChanged: pkgChanged,
    runSync: runSync,
  );
  if (addedSymbols.isEmpty) return null;

  final lookup =
      reverseDepLookup ??
      (runSync == defaultSyncProcessRunner
          ? discoverPublishedReverseDepConsumers
          : null);
  if (lookup == null) return null;

  final consumers = lookup(pkg.name, targetRelease);
  final collisions = findReverseDepApiCollisions(addedSymbols, consumers);
  if (collisions.isEmpty) return null;

  final details = collisions
      .map((c) => '    - ${c.formattedSummary}')
      .join('\n');
  return PrCheckViolation(
    check: 'rev-dep-api-collision',
    message:
        'Non-major release of package:${pkg.name} ($targetRelease, compatible '
        'with ^$baseVerStr) adds public API symbol(s) that collide with '
        '${collisions.length} published downstream consumer declaration(s):\n'
        '$details',
    remediation:
        'Export the new symbol(s) from a dedicated sub-library entrypoint, '
        'rename the symbol(s), bump package:${pkg.name} to a major version, '
        'or release downstream consumer updates with `show`/`hide` '
        'combinators first.',
  );
}

Future<ReverseDepLookup?> _buildCliReverseDepLookup({
  required Directory directory,
  required String? baseRefOverride,
  required SyncProcessRunner processRunner,
}) async {
  if (processRunner != defaultSyncProcessRunner) return null;
  final repoRoot = _resolveGitTopLevel(directory, processRunner) ?? directory;
  final baseRef = _resolveBaseRef(repoRoot, baseRefOverride, processRunner);
  final changedFiles = _collectChangedFiles(repoRoot, baseRef, processRunner);
  if (changedFiles.isEmpty) return null;

  final packages = runZoned(
    () => firehose.Repository(repoRoot).locatePackages(),
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );
  final changedSet = changedFiles.toSet();
  final preFetchedByPkg = <String, List<ReverseDepConsumer>>{};

  for (final pkg in packages) {
    final relDir = p.relative(pkg.directory.path, from: repoRoot.path);
    final prefix = relDir == '.' ? '' : '$relDir/';
    final pkgChanged = _packageRelativeChanges(prefix, changedSet);
    if (pkgChanged.isEmpty || pkg.version == null) continue;
    final baseVer = _readBasePubspecVersion(
      repoRoot,
      baseRef,
      '${prefix}pubspec.yaml',
      processRunner,
    );
    final targetRelease = nonMajorTargetReleaseVersion(pkg.version, baseVer);
    if (targetRelease == null) continue;
    final added = computePackageAddedPublicSymbols(
      repoRoot: repoRoot,
      baseRef: baseRef,
      pkg: pkg,
      prefix: prefix,
      pkgChanged: pkgChanged,
      runSync: processRunner,
    );
    if (added.isEmpty) continue;
    final pubDevConsumers = await fetchPubDevReverseDepConsumers(
      pkg.name,
      targetRelease,
    );
    preFetchedByPkg[pkg.name] = discoverPublishedReverseDepConsumers(
      pkg.name,
      targetRelease,
      preFetchedConsumers: pubDevConsumers,
    );
  }

  return (String pkgName, Version targetVer) =>
      preFetchedByPkg[pkgName] ??
      discoverPublishedReverseDepConsumers(pkgName, targetVer);
}
