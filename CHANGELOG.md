# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-09-23

### Added
- A `:roots` option for `PureFun.analyze/1` and `PureFun.Analyzer.analyze/2`. It limits the analysis to the functions that the given modules reach.

### Fixed
- `PureFun.Check.Purity` was not compiled when pure_fun was a dependency, because Credo was declared `only: [:dev, :test]`. Mix ignores such dependencies of a dependency, so whether the check existed depended on build order. `mix credo` then printed "Ignoring an undefined check" and passed.
- The README install snippet used `only: [:dev, :test]`, which breaks `MIX_ENV=prod mix compile` in any project with `use PureFun`.
- Analysis of a large build with dependencies took hours. Effects now settle once per strongly connected component instead of by repeated revisits, and only functions that the reported modules reach are analysed. On a Phoenix and Ecto project the full analysis went from 11 s to 0.5 s with identical verdicts.

### Changed
- A function passes at most 20 origins of each effect class on to its callers. Its own effects are always kept, and no class is ever dropped.
- `mix pure_fun` analyses only the project modules, or the modules named on the command line, and what they call. It prints a line before and after the analysis.
- Reasons are grouped by effect class and each origin is listed once. A verdict with several origins is printed as the verdict alone, followed by one line per class. The annotation is shown in brackets after the verdict.
- A report with unknown calls ends with how to resolve them.

## [0.1.0] - 2026-09-23

### Added
- Static purity analysis of BEAM functions from compiled code, including protocol and behaviour dispatch.
- `mix pure_fun` task.
- `@pure_fun` annotations: per-function claims, waivers and module-wide claims.
- `PureFun.Check.Purity`, a Credo check that is only compiled when the host project has Credo.
