// SDRC_HS IP instance naming macros
// module_name  — the user-visible wrapper module name
// getname      — Gowin name-mangling macro (creates hierarchical IP identifiers)

`define module_name Gowin_SDRAM_HS
`define getname(oriName, tmodule_name) \~oriName.tmodule_name
