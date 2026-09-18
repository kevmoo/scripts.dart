/// Canonical templates for analysis options, GitHub workflows, and dependabot.
library;

const String canonicalAnalysisOptions = '''
include: package:dart_flutter_team_lints/analysis_options.yaml

analyzer:
  language:
    strict-raw-types: true

linter:
  rules:
    - avoid_bool_literals_in_conditional_expressions
    - avoid_classes_with_only_static_members
    - avoid_private_typedef_functions
    - avoid_redundant_argument_values
    - avoid_returning_this
    - avoid_unused_constructor_parameters
    - avoid_void_async
    - cancel_subscriptions
    - cascade_invocations
    - join_return_with_assignment
    - literal_only_boolean_expressions
    - missing_whitespace_between_adjacent_strings
    - no_adjacent_strings_in_list
    - no_runtimeType_toString
    - prefer_const_declarations
    - prefer_expression_function_bodies
    - prefer_final_locals
    - require_trailing_commas
    - simple_directive_paths
    - unnecessary_await_in_return
    - unnecessary_ignore
    - use_raw_strings
    - use_string_buffers
''';

const String canonicalLowerBoundWorkflow = '''
name: Dependency Lower-Bound Validation

on:
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  validate:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
      contents: read
    steps:
      - name: Checkout Codebase
        uses: actions/checkout@v4

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Run Lower-Bound Validator
        uses: kevmoo/analytica.dart/packages/lower_bound@main
        with:
          format: 'github'
          fail-on-error: 'true'
''';

const String canonicalComplexityWorkflow = '''
name: Cognitive Complexity Audit

on:
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
      contents: read
    steps:
      - name: Checkout Codebase
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Run Complexity Scanner
        uses: kevmoo/analytica.dart/packages/cognitive_complexity@main
        with:
          diff-base: origin/\${{ github.base_ref }}
          fail-threshold: 15
          fail-on-increase: true
''';

const String canonicalAutosubmitWorkflow = '''
name: Autosubmit

on:
  pull_request_target:
    types: [labeled]

jobs:
  autosubmit:
    if: github.event.label.name == 'autosubmit'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - name: Enable Auto-Merge
        run: gh pr merge --auto --squash "\$PR_URL"
        env:
          GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
          PR_URL: \${{ github.event.pull_request.html_url }}
''';

const String canonicalDependabotConfig = '''
# Dependabot configuration file.
# See https://docs.github.com/en/code-security/dependabot/dependabot-version-updates
version: 2

updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: monthly
    labels:
      - autosubmit
    groups:
      github-actions:
        patterns:
          - "*"
''';

/// Prettier configuration, scoped to markdown via `overrides` so that a stray
/// `prettier --write .` cannot reformat `pubspec.yaml` or workflow YAML.
///
/// `embeddedLanguageFormatting: off` keeps prettier out of fenced code block
/// contents -- by default it reformats ```json and ```yaml bodies.
const String canonicalPrettierRc = '''
{
  "overrides": [
    {
      "files": ["**/*.md"],
      "options": {
        "proseWrap": "always",
        "printWidth": 80,
        "embeddedLanguageFormatting": "off"
      }
    }
  ]
}
''';

/// The markdown format check. The job ID is deliberately `markdown`, because
/// GitHub names the check run after the job ID and branch rulesets match that
/// string exactly.
const String canonicalMarkdownWorkflow =
    '''
name: Markdown

# Runs unconditionally on every PR to main -- deliberately NO `paths:` filter.
# This job is a required status check, and a path-filtered required check never
# reports on PRs that touch no markdown, blocking them forever at
# "Expected - waiting for status to be reported".

on:
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  # Job ID is the check-run context name the branch ruleset matches on.
  $markdownCheckContext:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version: "24"
      - run: npx --yes prettier@3.9.6 --check "**/*.md"
''';

/// The check-run context name produced by [canonicalMarkdownWorkflow]. This is
/// the job ID, which is what a branch ruleset must require.
const String markdownCheckContext = 'markdown';
