# Repository Guidelines

## Project Structure & Module Organization
Core runtime C code sits in `skynet-src/` (service scheduling, sockets, timers) and companion C services in `service-src/` (`service_snlua.c`, `service_gate.c`, etc.). Lua bridge bindings live in `lualib-src/`, while high-level Lua services ship under `service/` and reusable libraries under `lualib/`. Prebuilt C modules land in `luaclib/`. Reference applications and configs are in `examples/`, and focused validation scripts reside in `test/`. Keep third-party updates isolated to `3rd/` to avoid polluting versioned code.

## Build, Test, and Development Commands
- `make linux` (or `make macosx`, `make freebsd`): compile Skynet for your platform; set `PLAT=<target>` if you prefer `make` without arguments.
- `make clean` / `make cleanall`: remove build outputs; use the latter when dependencies in `3rd/` change.
- `./skynet examples/config`: start a local node with the default gate, logger, and launcher services.
- `./3rd/lua/lua examples/client.lua`: attach a demo client to the running node to verify message flow.

## Coding Style & Naming Conventions
Follow upstream Skynet conventions: C uses tabs for indentation, K&R brace placement, and `skynet_*` or `service_*` prefixes for new runtime files. Lua modules stay lowercase with underscores (e.g., `my_service.lua`) and prefer tabs for alignment, matching existing code. Keep comments bilingual only when necessary; otherwise default to concise English. Avoid introducing formatting tools that are not already configured in the repo.

## Testing Guidelines
Smoke-test new features by running the relevant scripts under `examples/` or `test/` with `./skynet <config>` when services are involved, or `./3rd/lua/lua test/<name>.lua` for library-level checks. Add new scenarios beside similar scripts (e.g., `test/testsocket.lua`) and name them descriptively. When altering cluster or network behaviour, demonstrate the change with an example config update or a documented manual test procedure.

## Commit & Pull Request Guidelines
Use concise imperative summaries (≤72 characters) with optional Chinese context, mirroring existing commits such as “重构项目结构：移除冗余文档到备份目录”. Group related changes per commit; avoid mixing third-party updates with core edits. Pull requests should describe the motivation, highlight impacted services or modules, list verification steps (`./skynet examples/config`, specific tests), and link any tracking issues. Include screenshots or logs only when they clarify runtime behaviour or regressions.
