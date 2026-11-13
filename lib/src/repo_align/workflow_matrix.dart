import 'package:yaml/yaml.dart';

final _deprecatedAnalyticaRegex = RegExp(
  r'uses:\s*kevmoo/analytica\.dart(?:/packages/lower_bound)?@',
);
final _matrixInterpolationRegex = RegExp(
  r'\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}',
);

/// Aggregated workflow capabilities extracted from `.github/workflows/`.
typedef WorkflowsScanInfo = ({
  List<String> files,
  bool hasCi,
  bool hasLowerBound,
  bool hasCogComp,
  bool hasAutosubmit,
  bool hasPublish,
  bool hasHealth,
  bool hasPostSummaries,
  bool hasDeprecatedAnalyticaRef,
  bool hasNarrowWorkflowsPathFilter,
  List<String> expectedCiCheckPrefixes,
});

const emptyWorkflowsScanInfo = (
  files: <String>[],
  hasCi: false,
  hasLowerBound: false,
  hasCogComp: false,
  hasAutosubmit: false,
  hasPublish: false,
  hasHealth: false,
  hasPostSummaries: false,
  hasDeprecatedAnalyticaRef: false,
  hasNarrowWorkflowsPathFilter: false,
  expectedCiCheckPrefixes: <String>[],
);

/// Inspects a map of workflow filenames to raw YAML contents.
WorkflowsScanInfo inspectWorkflowContents(Map<String, String> workflowFiles) {
  if (workflowFiles.isEmpty) return emptyWorkflowsScanInfo;

  final sortedNames = workflowFiles.keys.toList()..sort();
  final inspected = [
    for (final name in sortedNames)
      if (_isYamlWorkflowFilename(name))
        _inspectSingleWorkflow(name, workflowFiles[name]!),
  ];
  if (inspected.isEmpty) return emptyWorkflowsScanInfo;

  return (
    files: inspected.map((w) => w.name).toList(),
    hasCi: inspected.any((w) => w.hasCi),
    hasLowerBound: inspected.any((w) => w.hasLowerBound),
    hasCogComp: inspected.any((w) => w.hasCogComp),
    hasAutosubmit: inspected.any((w) => w.hasAutosubmit),
    hasPublish: inspected.any((w) => w.hasPublish),
    hasHealth: inspected.any((w) => w.hasHealth),
    hasPostSummaries: inspected.any((w) => w.hasPostSummaries),
    hasDeprecatedAnalyticaRef: inspected.any(
      (w) => w.hasDeprecatedAnalyticaRef,
    ),
    hasNarrowWorkflowsPathFilter: inspected.any(
      (w) => w.hasNarrowWorkflowsPathFilter,
    ),
    expectedCiCheckPrefixes: _dedupePreservingOrder(
      inspected.expand((w) => w.expectedCiCheckPrefixes),
    ),
  );
}

bool _isYamlWorkflowFilename(String name) =>
    name.endsWith('.yml') || name.endsWith('.yaml');

({
  String name,
  bool hasCi,
  bool hasLowerBound,
  bool hasCogComp,
  bool hasAutosubmit,
  bool hasPublish,
  bool hasHealth,
  bool hasPostSummaries,
  bool hasDeprecatedAnalyticaRef,
  bool hasNarrowWorkflowsPathFilter,
  List<String> expectedCiCheckPrefixes,
})
_inspectSingleWorkflow(String name, String content) {
  final isMarkdown = name == 'markdown.yml' || name == 'markdown.yaml';
  final hasLowerBound =
      content.contains('lower_bound') || content.contains('lower-bound');
  final hasCogComp =
      content.contains('cognitive_complexity') ||
      content.contains('cogcomp') ||
      name.contains('complexity');
  final hasAutosubmit =
      content.contains('autosubmit') || name.contains('autosubmit');
  final hasPublish =
      name.contains('publish') ||
      content.contains('dart-lang/setup-dart/.github/workflows/publish.yml') ||
      content.contains('dart-lang/ecosystem/.github/workflows/publish.yaml');
  final hasHealth =
      name.contains('health') ||
      content.contains('dart-lang/ecosystem/.github/workflows/health.yaml');
  final hasPostSummaries =
      name.contains('post_summaries') ||
      name.contains('post-summaries') ||
      content.contains(
        'dart-lang/ecosystem/.github/workflows/post_summaries.yaml',
      );
  final isAuxiliary =
      isMarkdown ||
      hasLowerBound ||
      (hasCogComp && !content.contains('dart test')) ||
      hasAutosubmit ||
      hasPublish ||
      hasHealth ||
      hasPostSummaries;
  final hasCi = !isAuxiliary && _looksLikePrimaryCiWorkflow(name, content);

  return (
    name: name,
    hasCi: hasCi,
    hasLowerBound: hasLowerBound,
    hasCogComp: hasCogComp,
    hasAutosubmit: hasAutosubmit,
    hasPublish: hasPublish,
    hasHealth: hasHealth,
    hasPostSummaries: hasPostSummaries,
    hasDeprecatedAnalyticaRef: _deprecatedAnalyticaRegex.hasMatch(content),
    hasNarrowWorkflowsPathFilter:
        content.contains('.github/workflows/**') &&
        !content.contains("'.github/**'") &&
        !content.contains('".github/**"'),
    expectedCiCheckPrefixes: hasCi
        ? extractWorkflowJobCheckNames(content)
        : const [],
  );
}

bool _looksLikePrimaryCiWorkflow(String name, String content) =>
    name.contains('ci') ||
    name.contains('dart') ||
    name.contains('test') ||
    name.contains('validate') ||
    content.contains('dart test') ||
    content.contains('flutter test') ||
    content.contains('dart analyze');

/// Expands all job check-run names declared in a GitHub Actions workflow YAML,
/// including Cartesian `strategy.matrix` combinations (`os`, `sdk`, `package`,
/// `exclude`, `include`, and `${{ matrix.<axis> }}` job-name templates).
List<String> extractWorkflowJobCheckNames(String content) {
  try {
    final doc = loadYaml(content);
    final jobs = doc is YamlMap ? doc['jobs'] : null;
    if (jobs is! YamlMap) return const [];
    return _dedupePreservingOrder(
      jobs.entries.expand(
        (e) => _expandJobCheckNames(e.key.toString(), e.value),
      ),
    );
  } catch (_) {
    return const [];
  }
}

List<String> _expandJobCheckNames(String jobKey, Object? jobVal) {
  if (jobVal is! YamlMap) return [jobKey];

  final rawName = jobVal['name']?.toString();
  final strategy = jobVal['strategy'];
  final matrix = strategy is YamlMap ? strategy['matrix'] : null;

  if (matrix is YamlMap) {
    final expanded = _expandMatrixJobNames(jobKey, rawName, matrix);
    if (expanded.isNotEmpty) return expanded;
  }

  if (rawName != null && !rawName.contains(r'${{')) {
    return [rawName];
  }
  return [jobKey];
}

List<String> _expandMatrixJobNames(
  String jobKey,
  String? rawName,
  YamlMap matrix,
) {
  final axes = <String, List<String>>{};
  for (final MapEntry(:key, :value) in matrix.entries) {
    final axis = key.toString();
    if (axis == 'include' || axis == 'exclude') continue;
    if (value is YamlList && value.isNotEmpty) {
      axes[axis] = value.map((v) => v.toString()).toList();
    }
  }

  var combos = _cartesianMatrixCombinations(axes);
  combos = _applyMatrixExcludes(combos, matrix['exclude']);
  combos = _applyMatrixIncludes(combos, axes.keys.toList(), matrix['include']);
  if (combos.isEmpty) return const [];

  // Preserve historical single-axis `package:` shorthand when no explicit
  // `name:` template is set and `package` is the sole matrix axis.
  if (rawName == null && axes.length == 1 && axes.containsKey('package')) {
    return combos.map((c) => c['package']!).toList();
  }

  return combos
      .map((combo) => _formatMatrixComboName(jobKey, rawName, combo))
      .toList();
}

List<Map<String, String>> _cartesianMatrixCombinations(
  Map<String, List<String>> axes,
) {
  if (axes.isEmpty) return const [];
  var combos = <Map<String, String>>[const {}];
  for (final MapEntry(key: axis, value: values) in axes.entries) {
    combos = [
      for (final prefix in combos)
        for (final val in values) {...prefix, axis: val},
    ];
  }
  return combos;
}

List<Map<String, String>> _applyMatrixExcludes(
  List<Map<String, String>> combos,
  Object? rawExclude,
) {
  if (rawExclude is! YamlList) return combos;
  final excludes = rawExclude.whereType<YamlMap>().toList();
  if (excludes.isEmpty) return combos;
  return combos
      .where((combo) => !excludes.any((ex) => _comboMatchesFilter(combo, ex)))
      .toList();
}

List<Map<String, String>> _applyMatrixIncludes(
  List<Map<String, String>> combos,
  List<String> baseAxes,
  Object? rawInclude,
) {
  if (rawInclude is! YamlList) return combos;
  final result = combos.map(Map<String, String>.from).toList();
  for (final item in rawInclude.whereType<YamlMap>()) {
    final extra = {
      for (final MapEntry(:key, :value) in item.entries)
        key.toString(): value.toString(),
    };
    final matchesExisting =
        baseAxes.isNotEmpty &&
        result.any((c) => _comboMatchesOnBaseAxes(c, extra, baseAxes));
    if (!matchesExisting) {
      result.add(extra);
    }
  }
  return result;
}

bool _comboMatchesFilter(Map<String, String> combo, YamlMap filter) =>
    filter.entries.every((e) => combo[e.key.toString()] == e.value?.toString());

bool _comboMatchesOnBaseAxes(
  Map<String, String> combo,
  Map<String, String> includeEntry,
  List<String> baseAxes,
) => baseAxes.every(
  (axis) =>
      !includeEntry.containsKey(axis) || combo[axis] == includeEntry[axis],
);

String _formatMatrixComboName(
  String jobKey,
  String? rawName,
  Map<String, String> combo,
) {
  if (rawName != null && _matrixInterpolationRegex.hasMatch(rawName)) {
    return rawName.replaceAllMapped(
      _matrixInterpolationRegex,
      (m) => combo[m.group(1)!] ?? '',
    );
  }
  final baseName = (rawName != null && !rawName.contains(r'${{'))
      ? rawName
      : jobKey;
  final suffix = combo.values.join(', ');
  return suffix.isEmpty ? baseName : '$baseName ($suffix)';
}

List<String> _dedupePreservingOrder(Iterable<String> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add(item)) item,
  ];
}
