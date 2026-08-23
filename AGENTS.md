# Repository instructions

- Keep this repository standalone. Runtime code must never import or execute files from a sibling pipeline repository.
- Add a short functional comment immediately above every new or materially changed PowerShell function and C# method.
- Keep Unity project copies, build outputs, caches, logs, and acceptance artifacts outside this repository and outside the source Unity project.
- Preserve the public parameter, schema, final-status, and verification-scope contracts unless a documented versioned change explicitly replaces them.
- Do not mark a Unity/Test Framework/module/backend/toolchain combination approved without parser fixtures and signed-Unity acceptance evidence.
- Never execute a Unity project, Player, or prebuilt executable from a C-drive validation, log, copy, or artifact path.
