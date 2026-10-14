# Review 2 — final outcome of every finding and verdict

Made by script from all `status/*.md` files (first pass, then second pass, then integration; the last row that names an
ID wins; 22 rows whose last wording was unclear were read and set by hand).

| Outcome       | Count |
| ------------- | ----- |
| fixed         | 604   |
| fixed in part | 4     |
| duplicate     | 192   |
| not a defect  | 32    |
| refuted       | 13    |
| not fixed     | 3     |
| **total**     | 848   |

## Open: not fixed or fixed in part

| ID   | Severity | Outcome       | Finding                                                                                                                                                                                                                                                       | Last note                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---- | -------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C057 | medium   | not fixed     | Branch view memory and re-walk storms.                                                                                                                                                                                                                        | (`plugins-a-p2.md`)                                                                                                                                                                                                                                                                                                                                                                                                              |
| C078 | low      | not fixed     | First child(named:) in a 1M-subfolder folder builds its index on main (53 ms).                                                                                                                                                                                | (`plugins-a-p2.md`)                                                                                                                                                                                                                                                                                                                                                                                                              |
| C079 | low      | not fixed     | reloadData + expandItem with an expanded folder of 1M subfolders takes 0.74 + 0.84 s (84 + 71 ms at 100k).                                                                                                                                                    | (`plugins-a-p2.md`)                                                                                                                                                                                                                                                                                                                                                                                                              |
| F043 | low      | fixed in part | Residual check-then-use races on paths: a folder swapped for a symlink between listing and use leads Delete, or the source removal of a Move, into the link's target; recursive chmod/date changes follow a link put in place after listing.                  | Local part done: `remove(_:below:cancellation:)` walks from the root through descriptors opened with `O_NOFOLLOW` and removes with `unlinkat`; exclusive `createDirectory` for Unpack. Test: `anItemOfATreeIsRemovedOnlyWhereTheTreeReallyIs` (a folder swapped for a link to a victim folder: nothing of the victim is removed). `FileJob` and `Unpacker` have to call them (cross-requests 2, 3, 9). (`integration.md`)        |
| L043 | low      | fixed in part | Symlink races on path-based operations in attacker-writable folders: unpack follows existing symlink-to-directory; Writer.close sets mode/time by path; recursive delete/copy re-open children by path; archive modes applied as stored incl. world-writable. | Local part done: `remove(_:below:cancellation:)` walks from the root through descriptors opened with `O_NOFOLLOW` and removes with `unlinkat`; exclusive `createDirectory` for Unpack. Test: `anItemOfATreeIsRemovedOnlyWhereTheTreeReallyIs` (a folder swapped for a link to a victim folder: nothing of the victim is removed). `FileJob` and `Unpacker` have to call them (cross-requests 2, 3, 9). (`integration.md`)        |
| X001 | low      | fixed in part | An ASan + UBSan full-suite run had 1 timing assertion failure.                                                                                                                                                                                                | The other wall-clock margins of ShellTests are gone or widened by conditions: `pluginColumnsAreFilledIn…` (18 ms margin removed), `aLargeFolderStaysFastInEveryView` (thread CPU time instead of wall time), `aRememberedFolderIsShownAtOnce…`, `aRememberedFolderInAnotherOrder…`, `movingTheCursorCancelsAReadAhead…` (the simulated server is slow enough for the test's turn to come). Not run under the san (`shell-p2.md`) |
| X002 | low      | fixed in part | Every TSan full-suite run (4) had failures; none was a race report.                                                                                                                                                                                           | The other wall-clock margins of ShellTests are gone or widened by conditions: `pluginColumnsAreFilledIn…` (18 ms margin removed), `aLargeFolderStaysFastInEveryView` (thread CPU time instead of wall time), `aRememberedFolderIsShownAtOnce…`, `aRememberedFolderInAnotherOrder…`, `movingTheCursorCancelsAReadAhead…` (the simulated server is slow enough for the test's turn to come). Not run under the san (`shell-p2.md`) |

## Found after the review (not in the findings files)

See `status/harnesses.md` (N1–N4, all fixed in `status/integration.md`) and `status/integration.md` section 2 (rows
10–13, 16, 17: defects found while integrating) and section 8 (what is still open).

## Every ID

| ID   | Area     | Kind    | Severity | Outcome                       | Status file     |
| ---- | -------- | ------- | -------- | ----------------------------- | --------------- |
| A001 | archives | finding | critical | fixed                         | archives.md     |
| A002 | archives | finding | critical | duplicate of A001             | archives.md     |
| A003 | archives | finding | critical | fixed                         | archives.md     |
| A004 | archives | finding | critical | duplicate of A003             | archives.md     |
| A005 | archives | finding | critical | fixed                         | archives.md     |
| A006 | archives | finding | high     | fixed                         | archives.md     |
| A007 | archives | finding | high     | fixed                         | archives.md     |
| A008 | archives | finding | high     | duplicate of A006             | archives.md     |
| A009 | archives | finding | high     | duplicate of A006             | archives.md     |
| A010 | archives | finding | high     | duplicate of A006             | archives.md     |
| A011 | archives | finding | high     | fixed                         | archives.md     |
| A012 | archives | verdict | high     | duplicate of A011             | archives.md     |
| A013 | archives | finding | high     | fixed                         | archives.md     |
| A014 | archives | finding | high     | duplicate of A006             | archives.md     |
| A015 | archives | finding | high     | duplicate of A003             | archives.md     |
| A016 | archives | verdict | high     | fixed                         | archives.md     |
| A017 | archives | finding | high     | duplicate of A016             | archives.md     |
| A018 | archives | finding | high     | fixed                         | archives.md     |
| A019 | archives | verdict | high     | duplicate of A018             | archives.md     |
| A020 | archives | verdict | high     | duplicate of A018             | archives.md     |
| A021 | archives | finding | medium   | fixed                         | archives.md     |
| A022 | archives | finding | medium   | fixed                         | archives.md     |
| A023 | archives | finding | medium   | fixed                         | archives.md     |
| A024 | archives | finding | medium   | duplicate of A021             | archives.md     |
| A025 | archives | finding | medium   | duplicate of A022             | archives.md     |
| A026 | archives | finding | medium   | fixed                         | archives.md     |
| A027 | archives | finding | medium   | fixed                         | archives.md     |
| A028 | archives | verdict | medium   | duplicate of A021             | archives.md     |
| A029 | archives | verdict | medium   | duplicate of A013             | archives.md     |
| A030 | archives | finding | medium   | duplicate of A005             | archives.md     |
| A031 | archives | finding | medium   | fixed                         | archives.md     |
| A032 | archives | verdict | medium   | duplicate of A006             | archives.md     |
| A033 | archives | finding | medium   | fixed                         | archives.md     |
| A034 | archives | finding | medium   | fixed                         | archives.md     |
| A035 | archives | finding | medium   | fixed                         | archives.md     |
| A036 | archives | verdict | medium   | duplicate of A035             | archives.md     |
| A037 | archives | verdict | medium   | duplicate of A034             | archives.md     |
| A038 | archives | finding | medium   | fixed                         | archives.md     |
| A039 | archives | finding | medium   | not a defect                  | archives.md     |
| A040 | archives | finding | medium   | fixed                         | archives.md     |
| A041 | archives | finding | medium   | fixed                         | fileops-p2.md   |
| A042 | archives | finding | medium   | fixed                         | archives.md     |
| A043 | archives | finding | medium   | fixed                         | archives.md     |
| A044 | archives | finding | medium   | fixed                         | fileops-p2.md   |
| A045 | archives | finding | medium   | fixed                         | archives.md     |
| A046 | archives | finding | medium   | fixed                         | archives.md     |
| A047 | archives | finding | medium   | fixed                         | archives.md     |
| A048 | archives | verdict | medium   | duplicate of A023             | archives.md     |
| A049 | archives | finding | medium   | fixed                         | archives.md     |
| A050 | archives | verdict | medium   | refuted                       | archives.md     |
| A051 | archives | finding | low      | fixed                         | archnet-p2.md   |
| A052 | archives | finding | low      | fixed                         | archives.md     |
| A053 | archives | finding | low      | fixed                         | archives.md     |
| A054 | archives | finding | low      | duplicate of A003             | archives.md     |
| A055 | archives | finding | low      | not a defect                  | archives.md     |
| A056 | archives | finding | low      | duplicate of A001             | archives.md     |
| A057 | archives | finding | low      | not a defect                  | archives.md     |
| A058 | archives | finding | low      | fixed                         | archives.md     |
| A059 | archives | finding | low      | fixed                         | archives.md     |
| A060 | archives | finding | low      | fixed                         | archives.md     |
| A061 | archives | finding | low      | fixed                         | archives.md     |
| A062 | archives | finding | low      | fixed                         | archives.md     |
| A063 | archives | finding | low      | not a defect                  | archives.md     |
| A064 | archives | finding | low      | fixed                         | archives.md     |
| A065 | archives | finding | low      | duplicate of A042             | archives.md     |
| A066 | archives | finding | low      | fixed                         | archives.md     |
| A067 | archives | finding | low      | fixed                         | archives.md     |
| A068 | archives | finding | low      | duplicate of A066             | archives.md     |
| A069 | archives | finding | low      | fixed                         | archives.md     |
| A070 | archives | finding | low      | not a defect                  | archives.md     |
| A071 | archives | finding | low      | duplicate of A052             | archives.md     |
| A072 | archives | finding | low      | duplicate of A021             | archives.md     |
| A073 | archives | finding | low      | fixed                         | archives.md     |
| A074 | archives | finding | low      | fixed                         | archives.md     |
| A075 | archives | finding | low      | fixed                         | archives.md     |
| A076 | archives | finding | low      | fixed                         | archnet-p2.md   |
| A077 | archives | verdict | low      | duplicate of A005             | archives.md     |
| A078 | archives | finding | low      | fixed                         | archives.md     |
| A079 | archives | verdict | low      | fixed                         | archives.md     |
| A080 | archives | finding | low      | fixed                         | archives.md     |
| A081 | archives | finding | low      | fixed                         | archives.md     |
| A082 | archives | finding | low      | fixed                         | archives.md     |
| A083 | archives | finding | low      | fixed                         | archives.md     |
| A084 | archives | finding | low      | fixed                         | archives.md     |
| A085 | archives | finding | low      | fixed                         | archives.md     |
| A086 | archives | verdict | low      | fixed                         | archives.md     |
| A087 | archives | verdict | low      | duplicate of A038             | archives.md     |
| A088 | archives | finding | low      | fixed                         | archives.md     |
| A089 | archives | finding | low      | fixed                         | archives.md     |
| A090 | archives | finding | low      | fixed                         | archives.md     |
| A091 | archives | verdict | low      | duplicate of A003             | archives.md     |
| A092 | archives | finding | low      | duplicate of A062             | archives.md     |
| A093 | archives | verdict | low      | refuted                       | archives.md     |
| A094 | archives | finding | low      | fixed                         | archives.md     |
| A095 | archives | finding | low      | duplicate of A018             | archives.md     |
| A096 | archives | finding | low      | fixed                         | archives.md     |
| A097 | archives | finding | low      | duplicate of A096             | archives.md     |
| A098 | archives | finding | low      | fixed                         | archives.md     |
| A099 | archives | finding | low      | fixed                         | archives.md     |
| A100 | archives | finding | info     | not a defect                  | archives.md     |
| A101 | archives | finding | info     | duplicate of A033             | archives.md     |
| A102 | archives | finding | info     | fixed                         | archives.md     |
| A103 | archives | finding | info     | not a defect                  | archives.md     |
| A104 | archives | finding | info     | fixed                         | archnet-p2.md   |
| C001 | config   | finding | critical | fixed                         | config-a.md     |
| C002 | config   | finding | critical | fixed                         | config-a.md     |
| C003 | config   | finding | high     | fixed                         | config-a.md     |
| C004 | config   | finding | high     | fixed                         | config-b.md     |
| C005 | config   | finding | high     | duplicate of C004             | config-b.md     |
| C006 | config   | finding | high     | fixed                         | config-b.md     |
| C007 | config   | finding | high     | fixed                         | config-b.md     |
| C008 | config   | finding | high     | fixed                         | config-b.md     |
| C009 | config   | finding | high     | duplicate of C008             | config-b.md     |
| C010 | config   | finding | high     | fixed                         | config-b.md     |
| C011 | config   | finding | high     | fixed                         | plugins-a-p2.md |
| C012 | config   | finding | high     | fixed                         | plugins-a-p2.md |
| C013 | config   | finding | high     | fixed                         | config-a.md     |
| C014 | config   | verdict | high     | fixed                         | config-a.md     |
| C015 | config   | verdict | high     | fixed                         | config-a.md     |
| C016 | config   | finding | high     | fixed                         | config-a.md     |
| C017 | config   | verdict | high     | fixed                         | config-a.md     |
| C018 | config   | finding | high     | duplicate of C017             | config-a.md     |
| C019 | config   | finding | high     | fixed                         | config-a.md     |
| C020 | config   | finding | high     | duplicate of C019             | config-a.md     |
| C021 | config   | finding | high     | duplicate of C002             | config-a.md     |
| C022 | config   | finding | high     | duplicate of C002             | config-a.md     |
| C023 | config   | verdict | high     | fixed                         | config-a.md     |
| C024 | config   | finding | high     | fixed                         | plugins-a-p2.md |
| C025 | config   | finding | high     | duplicate of C024             | plugins-a-p2.md |
| C026 | config   | finding | high     | fixed                         | config-a.md     |
| C027 | config   | finding | medium   | fixed                         | config-a.md     |
| C028 | config   | finding | medium   | fixed                         | plugins-a-p2.md |
| C029 | config   | finding | medium   | fixed                         | config-b.md     |
| C030 | config   | finding | medium   | fixed                         | config-a.md     |
| C031 | config   | finding | medium   | fixed                         | config-a.md     |
| C032 | config   | finding | medium   | fixed                         | config-a.md     |
| C033 | config   | finding | medium   | fixed                         | config-a.md     |
| C034 | config   | finding | medium   | fixed                         | config-b.md     |
| C035 | config   | finding | medium   | duplicate of C013             | config-a.md     |
| C036 | config   | finding | medium   | duplicate of C032             | config-a.md     |
| C037 | config   | finding | medium   | duplicate of C034             | config-b.md     |
| C038 | config   | finding | medium   | fixed                         | config-a.md     |
| C039 | config   | finding | medium   | duplicate of C008             | config-b.md     |
| C040 | config   | finding | medium   | fixed                         | config-b.md     |
| C041 | config   | finding | medium   | fixed                         | config-a.md     |
| C042 | config   | verdict | medium   | fixed                         | config-a.md     |
| C043 | config   | verdict | medium   | fixed                         | config-a.md     |
| C044 | config   | finding | medium   | fixed                         | config-a.md     |
| C045 | config   | finding | medium   | fixed                         | config-a.md     |
| C046 | config   | verdict | medium   | fixed                         | config-a.md     |
| C047 | config   | finding | medium   | fixed                         | config-a.md     |
| C048 | config   | finding | medium   | not a defect                  | shell-p2.md     |
| C049 | config   | finding | medium   | duplicate of C016             | config-a.md     |
| C050 | config   | finding | medium   | fixed                         | config-a.md     |
| C051 | config   | finding | medium   | duplicate of C032             | config-a.md     |
| C052 | config   | verdict | medium   | duplicate of C004             | config-b.md     |
| C053 | config   | finding | medium   | fixed                         | shell-p2.md     |
| C054 | config   | finding | medium   | fixed                         | config-a.md     |
| C055 | config   | finding | medium   | fixed                         | config-a.md     |
| C056 | config   | finding | medium   | duplicate of C026             | config-a.md     |
| C057 | config   | finding | medium   | not fixed                     | plugins-a-p2.md |
| C058 | config   | finding | medium   | duplicate of C006             | config-b.md     |
| C059 | config   | verdict | medium   | duplicate of C006             | config-b.md     |
| C060 | config   | verdict | medium   | duplicate of C008             | config-b.md     |
| C061 | config   | finding | medium   | fixed                         | config-b.md     |
| C062 | config   | finding | medium   | fixed                         | config-a.md     |
| C063 | config   | finding | medium   | fixed                         | config-a.md     |
| C064 | config   | finding | low      | fixed                         | config-a.md     |
| C065 | config   | finding | low      | fixed                         | config-a.md     |
| C066 | config   | finding | low      | fixed                         | config-a.md     |
| C067 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C068 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C069 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C070 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C071 | config   | finding | low      | fixed                         | config-b.md     |
| C072 | config   | finding | low      | fixed                         | shell-p2.md     |
| C073 | config   | finding | low      | fixed                         | config-b.md     |
| C074 | config   | finding | low      | fixed                         | config-b.md     |
| C075 | config   | finding | low      | fixed                         | config-b.md     |
| C076 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C077 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C078 | config   | finding | low      | not fixed                     | plugins-a-p2.md |
| C079 | config   | finding | low      | not fixed                     | plugins-a-p2.md |
| C080 | config   | finding | low      | fixed                         | config-b.md     |
| C081 | config   | finding | low      | not a defect                  | config-b.md     |
| C082 | config   | finding | low      | not a defect                  | config-b.md     |
| C083 | config   | finding | low      | duplicate of C027             | config-a.md     |
| C084 | config   | finding | low      | duplicate of C044             | config-a.md     |
| C085 | config   | finding | low      | duplicate of C047             | config-a.md     |
| C086 | config   | finding | low      | fixed                         | config-a.md     |
| C087 | config   | finding | low      | fixed                         | config-a.md     |
| C088 | config   | finding | low      | fixed                         | config-a.md     |
| C089 | config   | finding | low      | duplicate of C003             | config-a.md     |
| C090 | config   | finding | low      | duplicate of C032             | config-a.md     |
| C091 | config   | finding | low      | duplicate of C001             | config-a.md     |
| C092 | config   | finding | low      | fixed                         | config-b.md     |
| C093 | config   | finding | low      | fixed                         | config-b.md     |
| C094 | config   | finding | low      | fixed                         | config-b.md     |
| C095 | config   | finding | low      | duplicate of C054             | config-a.md     |
| C096 | config   | finding | low      | fixed                         | config-b.md     |
| C097 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C098 | config   | verdict | low      | fixed                         | config-a.md     |
| C099 | config   | finding | low      | not a defect                  | config-a.md     |
| C100 | config   | verdict | low      | refuted                       | config-a.md     |
| C101 | config   | finding | low      | fixed                         | config-a.md     |
| C102 | config   | finding | low      | fixed                         | config-a.md     |
| C103 | config   | finding | low      | fixed                         | config-a.md     |
| C104 | config   | finding | low      | fixed                         | config-a.md     |
| C105 | config   | verdict | low      | fixed                         | config-a.md     |
| C106 | config   | finding | low      | fixed                         | config-a.md     |
| C107 | config   | finding | low      | fixed                         | config-a.md     |
| C108 | config   | finding | low      | fixed                         | config-a.md     |
| C109 | config   | finding | low      | fixed                         | config-a.md     |
| C110 | config   | verdict | low      | fixed                         | config-b.md     |
| C111 | config   | verdict | low      | fixed                         | shell-p2.md     |
| C112 | config   | finding | low      | fixed                         | config-b.md     |
| C113 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C114 | config   | finding | low      | fixed                         | config-b.md     |
| C115 | config   | finding | low      | fixed                         | config-b.md     |
| C116 | config   | finding | low      | fixed                         | config-b.md     |
| C117 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C118 | config   | finding | low      | fixed                         | config-b.md     |
| C119 | config   | finding | low      | fixed                         | config-b.md     |
| C120 | config   | finding | low      | fixed                         | config-b.md     |
| C121 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C122 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C123 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C124 | config   | finding | low      | fixed                         | plugins-a-p2.md |
| C125 | config   | finding | low      | fixed                         | config-a.md     |
| C126 | config   | finding | low      | fixed                         | config-a.md     |
| C127 | config   | finding | low      | fixed                         | config-a.md     |
| C128 | config   | verdict | info     | not a defect                  | config-a.md     |
| C129 | config   | finding | info     | fixed                         | config-b.md     |
| F001 | fileops  | finding | critical | fixed                         | fileops-p2.md   |
| F002 | fileops  | finding | high     | fixed                         | shell-p2.md     |
| F003 | fileops  | finding | high     | fixed                         | fileops-p2.md   |
| F004 | fileops  | finding | high     | fixed                         | fileops.md      |
| F005 | fileops  | finding | high     | fixed                         | fileops.md      |
| F006 | fileops  | finding | high     | fixed                         | fileops.md      |
| F007 | fileops  | finding | high     | fixed                         | fileops.md      |
| F008 | fileops  | finding | high     | fixed                         | fileops-p2.md   |
| F009 | fileops  | finding | high     | fixed                         | fileops-p2.md   |
| F010 | fileops  | finding | high     | fixed                         | fileops-p2.md   |
| F011 | fileops  | verdict | high     | fixed                         | shell-p2.md     |
| F012 | fileops  | verdict | high     | fixed                         | fileops.md      |
| F013 | fileops  | verdict | high     | duplicate of F006             | fileops.md      |
| F014 | fileops  | finding | high     | fixed (first pass)            | fileops-p2.md   |
| F015 | fileops  | finding | high     | fixed (first pass)            | fileops-p2.md   |
| F016 | fileops  | finding | high     | fixed (first pass)            | fileops-p2.md   |
| F017 | fileops  | verdict | high     | duplicate of F007             | fileops.md      |
| F018 | fileops  | verdict | high     | fixed                         | fileops-p2.md   |
| F019 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F020 | fileops  | finding | medium   | duplicate of F012             | fileops.md      |
| F021 | fileops  | finding | medium   | fixed                         | fileops-p2.md   |
| F022 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F023 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F024 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F025 | fileops  | finding | medium   | fixed                         | plugins-b-p2.md |
| F026 | fileops  | finding | medium   | fixed                         | fileops-p2.md   |
| F027 | fileops  | finding | medium   | fixed                         | fileops-p2.md   |
| F028 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F029 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F030 | fileops  | finding | medium   | duplicate of F029             | fileops.md      |
| F031 | fileops  | verdict | medium   | duplicate of F019             | fileops.md      |
| F032 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F033 | fileops  | verdict | medium   | duplicate of F022             | fileops.md      |
| F034 | fileops  | finding | medium   | fixed                         | fileops.md      |
| F035 | fileops  | finding | low      | duplicate of F074             | fileops.md      |
| F036 | fileops  | finding | low      | fixed                         | fileops.md      |
| F037 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F038 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F039 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F040 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F041 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F042 | fileops  | finding | low      | fixed                         | fileops.md      |
| F043 | fileops  | finding | low      | fixed in part                 | integration.md  |
| F044 | fileops  | finding | low      | fixed                         | fileops.md      |
| F045 | fileops  | finding | low      | fixed                         | fileops.md      |
| F046 | fileops  | finding | low      | fixed                         | integration.md  |
| F047 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F048 | fileops  | finding | low      | fixed                         | fileops.md      |
| F049 | fileops  | finding | low      | fixed                         | fileops.md      |
| F050 | fileops  | finding | low      | fixed                         | fileops.md      |
| F051 | fileops  | finding | low      | fixed                         | fileops.md      |
| F052 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F053 | fileops  | finding | low      | fixed                         | fileops.md      |
| F054 | fileops  | finding | low      | fixed                         | fileops.md      |
| F055 | fileops  | finding | low      | fixed                         | shell-p2.md     |
| F056 | fileops  | finding | low      | fixed                         | fileops.md      |
| F057 | fileops  | finding | low      | fixed                         | fileops.md      |
| F058 | fileops  | finding | low      | fixed                         | archnet-p2.md   |
| F059 | fileops  | finding | low      | fixed                         | fileops.md      |
| F060 | fileops  | finding | low      | fixed                         | fileops.md      |
| F061 | fileops  | finding | low      | fixed                         | fileops.md      |
| F062 | fileops  | finding | low      | fixed                         | fileops.md      |
| F063 | fileops  | finding | low      | fixed                         | fileops.md      |
| F064 | fileops  | finding | low      | fixed                         | fileops.md      |
| F065 | fileops  | finding | low      | duplicate of F036             | fileops.md      |
| F066 | fileops  | finding | low      | fixed                         | fileops.md      |
| F067 | fileops  | finding | low      | fixed                         | fileops.md      |
| F068 | fileops  | finding | low      | fixed                         | fileops.md      |
| F069 | fileops  | finding | low      | fixed                         | fileops.md      |
| F070 | fileops  | finding | low      | fixed                         | fileops-p2.md   |
| F071 | fileops  | finding | low      | fixed                         | fileops.md      |
| F072 | fileops  | verdict | low      | duplicate of F023             | fileops.md      |
| F073 | fileops  | verdict | low      | duplicate of F024             | fileops.md      |
| F074 | fileops  | finding | low      | fixed (first pass)            | fileops-p2.md   |
| F075 | fileops  | finding | low      | fixed (first pass)            | fileops-p2.md   |
| F076 | fileops  | verdict | low      | duplicate of F028             | fileops.md      |
| F077 | fileops  | finding | low      | fixed                         | fileops.md      |
| F078 | fileops  | finding | low      | fixed                         | fileops.md      |
| F079 | fileops  | finding | info     | not a defect                  | fileops-p2.md   |
| F080 | fileops  | finding | info     | fixed                         | fileops.md      |
| F081 | fileops  | finding | info     | fixed                         | archnet-p2.md   |
| G001 | general  | finding | high     | fixed                         | kernel-p2.md    |
| G002 | general  | finding | low      | fixed (first pass, F077/F078) | fileops-p2.md   |
| G003 | general  | finding | low      | fixed                         | kernel-p2.md    |
| G004 | general  | finding | low      | fixed                         | kernel-p2.md    |
| G005 | general  | finding | info     | duplicate of S009             | shell.md        |
| K001 | kernel   | finding | critical | fixed                         | kernel.md       |
| K002 | kernel   | finding | critical | duplicate of K001             | kernel.md       |
| K003 | kernel   | finding | high     | fixed                         | kernel.md       |
| K004 | kernel   | finding | high     | fixed                         | kernel-p2.md    |
| K005 | kernel   | verdict | high     | fixed                         | kernel.md       |
| K006 | kernel   | finding | high     | fixed                         | kernel.md       |
| K007 | kernel   | verdict | high     | fixed                         | kernel-p2.md    |
| K008 | kernel   | finding | high     | fixed                         | kernel.md       |
| K009 | kernel   | finding | high     | duplicate of K008             | kernel.md       |
| K010 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K011 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K012 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K013 | kernel   | finding | medium   | fixed                         | shell-p2.md     |
| K014 | kernel   | verdict | medium   | fixed                         | shell-p2.md     |
| K015 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K016 | kernel   | verdict | medium   | fixed                         | kernel.md       |
| K017 | kernel   | verdict | medium   | fixed                         | kernel.md       |
| K018 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K019 | kernel   | verdict | medium   | fixed                         | kernel.md       |
| K020 | kernel   | finding | medium   | duplicate of K019             | kernel.md       |
| K021 | kernel   | verdict | medium   | fixed                         | kernel.md       |
| K022 | kernel   | verdict | medium   | fixed                         | kernel.md       |
| K023 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K024 | kernel   | verdict | medium   | fixed                         | kernel.md       |
| K025 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K026 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K027 | kernel   | finding | medium   | fixed                         | kernel.md       |
| K028 | kernel   | verdict | medium   | duplicate of K008             | kernel.md       |
| K029 | kernel   | verdict | medium   | duplicate of K006             | kernel.md       |
| K030 | kernel   | finding | low      | fixed                         | kernel.md       |
| K031 | kernel   | finding | low      | not a defect                  | kernel.md       |
| K032 | kernel   | finding | low      | fixed                         | kernel.md       |
| K033 | kernel   | finding | low      | fixed                         | kernel-p2.md    |
| K034 | kernel   | finding | low      | fixed                         | kernel.md       |
| K035 | kernel   | verdict | low      | fixed                         | kernel.md       |
| K036 | kernel   | verdict | low      | fixed                         | kernel.md       |
| K037 | kernel   | finding | low      | fixed                         | kernel.md       |
| K038 | kernel   | verdict | low      | duplicate of K003             | kernel.md       |
| K039 | kernel   | finding | low      | fixed                         | archnet-p2.md   |
| K040 | kernel   | finding | low      | fixed                         | kernel-p2.md    |
| K041 | kernel   | finding | low      | fixed                         | kernel.md       |
| K042 | kernel   | finding | low      | fixed                         | kernel.md       |
| K043 | kernel   | finding | low      | fixed                         | kernel.md       |
| K044 | kernel   | finding | low      | fixed                         | kernel.md       |
| K045 | kernel   | finding | low      | fixed                         | kernel.md       |
| K046 | kernel   | finding | low      | not a defect                  | kernel.md       |
| K047 | kernel   | finding | low      | fixed                         | plugins-a-p2.md |
| K048 | kernel   | verdict | low      | refuted                       | kernel.md       |
| K049 | kernel   | finding | low      | fixed                         | kernel.md       |
| K050 | kernel   | finding | low      | fixed                         | kernel.md       |
| K051 | kernel   | finding | low      | fixed                         | kernel.md       |
| K052 | kernel   | finding | low      | fixed                         | kernel.md       |
| K053 | kernel   | verdict | low      | duplicate of K028             | kernel.md       |
| K054 | kernel   | finding | info     | fixed                         | kernel.md       |
| K055 | kernel   | finding | info     | not a defect                  | kernel.md       |
| K056 | kernel   | verdict | info     | duplicate of K007             | kernel.md       |
| L001 | localfs  | finding | critical | fixed                         | localfs.md      |
| L002 | localfs  | finding | critical | duplicate of L001             | localfs.md      |
| L003 | localfs  | finding | high     | fixed                         | localfs.md      |
| L004 | localfs  | finding | high     | fixed                         | localfs.md      |
| L005 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L006 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L007 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L008 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L009 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L010 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L011 | localfs  | finding | medium   | fixed                         | localfs.md      |
| L012 | localfs  | finding | medium   | duplicate of L004             | localfs.md      |
| L013 | localfs  | finding | medium   | duplicate of L004             | localfs.md      |
| L014 | localfs  | verdict | medium   | duplicate of L001             | localfs.md      |
| L015 | localfs  | verdict | medium   | duplicate of L005             | localfs.md      |
| L016 | localfs  | finding | medium   | fixed                         | plugins-b-p2.md |
| L017 | localfs  | verdict | medium   | duplicate of L009             | localfs.md      |
| L018 | localfs  | verdict | medium   | duplicate of L010             | localfs.md      |
| L019 | localfs  | verdict | medium   | not a defect                  | localfs.md      |
| L020 | localfs  | verdict | medium   | fixed                         | localfs.md      |
| L021 | localfs  | verdict | medium   | duplicate of L004             | localfs.md      |
| L022 | localfs  | finding | low      | fixed                         | localfs.md      |
| L023 | localfs  | finding | low      | fixed                         | kernel-p2.md    |
| L024 | localfs  | finding | low      | fixed                         | localfs.md      |
| L025 | localfs  | finding | low      | fixed                         | localfs.md      |
| L026 | localfs  | finding | low      | fixed                         | localfs.md      |
| L027 | localfs  | finding | low      | fixed                         | localfs.md      |
| L028 | localfs  | finding | low      | fixed                         | localfs.md      |
| L029 | localfs  | finding | low      | fixed                         | kernel-p2.md    |
| L030 | localfs  | finding | low      | fixed                         | localfs.md      |
| L031 | localfs  | finding | low      | fixed                         | localfs.md      |
| L032 | localfs  | finding | low      | fixed                         | kernel-p2.md    |
| L033 | localfs  | finding | low      | fixed                         | localfs.md      |
| L034 | localfs  | finding | low      | fixed                         | localfs.md      |
| L035 | localfs  | finding | low      | fixed                         | localfs.md      |
| L036 | localfs  | finding | low      | fixed                         | localfs.md      |
| L037 | localfs  | finding | low      | fixed                         | localfs.md      |
| L038 | localfs  | finding | low      | fixed                         | localfs.md      |
| L039 | localfs  | finding | low      | fixed                         | localfs.md      |
| L040 | localfs  | finding | low      | fixed                         | localfs.md      |
| L041 | localfs  | finding | low      | fixed                         | localfs.md      |
| L042 | localfs  | finding | low      | fixed                         | localfs.md      |
| L043 | localfs  | finding | low      | fixed in part                 | integration.md  |
| L044 | localfs  | finding | low      | duplicate of L004             | localfs.md      |
| L045 | localfs  | verdict | low      | duplicate of L008             | localfs.md      |
| L046 | localfs  | verdict | low      | fixed                         | localfs.md      |
| L047 | localfs  | finding | info     | fixed                         | localfs.md      |
| N001 | network  | finding | critical | fixed                         | network.md      |
| N002 | network  | finding | critical | fixed                         | network.md      |
| N003 | network  | finding | high     | fixed                         | network.md      |
| N004 | network  | finding | high     | fixed                         | network.md      |
| N005 | network  | finding | high     | fixed                         | network.md      |
| N006 | network  | verdict | high     | refuted                       | network.md      |
| N007 | network  | verdict | high     | fixed                         | network.md      |
| N008 | network  | finding | high     | fixed                         | network.md      |
| N009 | network  | finding | medium   | fixed                         | fileops-p2.md   |
| N010 | network  | finding | medium   | fixed                         | archnet-p2.md   |
| N011 | network  | finding | medium   | fixed                         | network.md      |
| N012 | network  | finding | medium   | fixed                         | network.md      |
| N013 | network  | finding | medium   | duplicate of N012             | network.md      |
| N014 | network  | finding | medium   | fixed                         | network.md      |
| N015 | network  | finding | medium   | duplicate of N014             | network.md      |
| N016 | network  | finding | medium   | fixed                         | network.md      |
| N017 | network  | finding | medium   | fixed                         | network.md      |
| N018 | network  | finding | medium   | fixed                         | network.md      |
| N019 | network  | verdict | medium   | duplicate of N009             | network.md      |
| N020 | network  | finding | medium   | fixed                         | network.md      |
| N021 | network  | finding | medium   | fixed                         | network.md      |
| N022 | network  | finding | medium   | fixed                         | network.md      |
| N023 | network  | finding | medium   | fixed                         | network.md      |
| N024 | network  | verdict | medium   | fixed                         | network.md      |
| N025 | network  | finding | medium   | fixed                         | network.md      |
| N026 | network  | finding | medium   | fixed                         | archnet-p2.md   |
| N027 | network  | finding | medium   | fixed                         | network.md      |
| N028 | network  | finding | medium   | fixed                         | network.md      |
| N029 | network  | finding | medium   | fixed                         | network.md      |
| N030 | network  | finding | medium   | fixed                         | shell-p2.md     |
| N031 | network  | verdict | medium   | duplicate of N030             | network.md      |
| N032 | network  | finding | medium   | fixed                         | network.md      |
| N033 | network  | verdict | medium   | duplicate of N016             | network.md      |
| N034 | network  | finding | medium   | fixed                         | network.md      |
| N035 | network  | finding | medium   | fixed                         | network.md      |
| N036 | network  | finding | medium   | fixed                         | network.md      |
| N037 | network  | finding | medium   | fixed                         | network.md      |
| N038 | network  | finding | medium   | fixed                         | network.md      |
| N039 | network  | finding | medium   | fixed                         | network.md      |
| N040 | network  | finding | medium   | fixed                         | network.md      |
| N041 | network  | finding | medium   | fixed                         | network.md      |
| N042 | network  | finding | low      | fixed                         | network.md      |
| N043 | network  | finding | low      | not a defect                  | network.md      |
| N044 | network  | finding | low      | fixed                         | network.md      |
| N045 | network  | finding | low      | duplicate of N044             | network.md      |
| N046 | network  | finding | low      | duplicate of N010             | network.md      |
| N047 | network  | finding | low      | fixed                         | network.md      |
| N048 | network  | finding | low      | fixed                         | network.md      |
| N049 | network  | finding | low      | fixed                         | network.md      |
| N050 | network  | finding | low      | duplicate of N051             | network.md      |
| N051 | network  | finding | low      | fixed                         | network.md      |
| N052 | network  | finding | low      | fixed                         | network.md      |
| N053 | network  | finding | low      | duplicate of N011             | network.md      |
| N054 | network  | finding | low      | duplicate of N035             | network.md      |
| N055 | network  | finding | low      | duplicate of N056             | network.md      |
| N056 | network  | finding | low      | fixed                         | network.md      |
| N057 | network  | finding | low      | fixed (test added)            | archnet-p2.md   |
| N058 | network  | finding | low      | duplicate of N014             | network.md      |
| N059 | network  | finding | low      | duplicate of N014             | network.md      |
| N060 | network  | finding | low      | fixed                         | network.md      |
| N061 | network  | finding | low      | duplicate of N036             | network.md      |
| N062 | network  | finding | low      | not a defect                  | network.md      |
| N063 | network  | finding | low      | duplicate of N064             | network.md      |
| N064 | network  | finding | low      | fixed                         | network.md      |
| N065 | network  | finding | low      | fixed                         | network.md      |
| N066 | network  | finding | low      | fixed (test added)            | archnet-p2.md   |
| N067 | network  | finding | low      | duplicate of N009             | network.md      |
| N068 | network  | finding | low      | fixed                         | network.md      |
| N069 | network  | finding | low      | duplicate of N032             | network.md      |
| N070 | network  | finding | low      | fixed                         | network.md      |
| N071 | network  | finding | low      | fixed                         | shell-p2.md     |
| N072 | network  | finding | low      | duplicate of N018             | network.md      |
| N073 | network  | finding | low      | fixed                         | network.md      |
| N074 | network  | finding | low      | fixed                         | network.md      |
| N075 | network  | verdict | low      | duplicate of N020             | network.md      |
| N076 | network  | finding | low      | fixed                         | network.md      |
| N077 | network  | finding | low      | fixed                         | network.md      |
| N078 | network  | finding | low      | duplicate of N056             | network.md      |
| N079 | network  | verdict | low      | duplicate of N012             | network.md      |
| N080 | network  | finding | low      | fixed                         | network.md      |
| N081 | network  | verdict | low      | duplicate of N032             | network.md      |
| N082 | network  | finding | low      | duplicate of N014             | network.md      |
| N083 | network  | verdict | low      | fixed                         | network.md      |
| N084 | network  | finding | low      | duplicate of N083             | network.md      |
| N085 | network  | finding | low      | fixed                         | network.md      |
| N086 | network  | verdict | low      | fixed                         | network.md      |
| N087 | network  | finding | low      | fixed                         | network.md      |
| N088 | network  | finding | low      | fixed                         | network.md      |
| N089 | network  | finding | low      | fixed                         | network.md      |
| N090 | network  | finding | low      | fixed                         | network.md      |
| N091 | network  | finding | low      | fixed                         | network.md      |
| N092 | network  | finding | low      | fixed                         | network.md      |
| N093 | network  | finding | low      | duplicate of N064             | network.md      |
| N094 | network  | finding | low      | fixed                         | network.md      |
| N095 | network  | finding | low      | fixed                         | network.md      |
| N096 | network  | finding | low      | fixed                         | network.md      |
| N097 | network  | finding | low      | fixed                         | network.md      |
| N098 | network  | verdict | low      | refuted                       | network.md      |
| N099 | network  | finding | low      | fixed                         | network.md      |
| N100 | network  | finding | low      | fixed (test added)            | archnet-p2.md   |
| N101 | network  | finding | low      | fixed                         | network.md      |
| N102 | network  | verdict | low      | refuted                       | network.md      |
| N103 | network  | finding | low      | fixed (test added)            | archnet-p2.md   |
| N104 | network  | finding | low      | fixed                         | network.md      |
| N105 | network  | verdict | low      | duplicate of N104             | network.md      |
| N106 | network  | finding | info     | not a defect                  | network.md      |
| N107 | network  | finding | info     | duplicate of N047             | network.md      |
| N108 | network  | finding | info     | not a defect                  | network.md      |
| R001 | find     | finding | critical | fixed                         | find.md         |
| R002 | find     | finding | high     | fixed                         | find.md         |
| R003 | find     | finding | high     | fixed                         | find.md         |
| R004 | find     | finding | high     | duplicate of R003             | find.md         |
| R005 | find     | finding | high     | fixed                         | find.md         |
| R006 | find     | finding | high     | fixed                         | find.md         |
| R007 | find     | finding | high     | duplicate of R003             | find.md         |
| R008 | find     | finding | high     | duplicate of R005             | find.md         |
| R009 | find     | finding | high     | duplicate of R006             | find.md         |
| R010 | find     | finding | high     | fixed                         | find.md         |
| R011 | find     | finding | high     | fixed                         | plugins-a-p2.md |
| R012 | find     | finding | high     | fixed                         | find.md         |
| R013 | find     | verdict | high     | fixed                         | find.md         |
| R014 | find     | finding | high     | fixed                         | find.md         |
| R015 | find     | finding | high     | duplicate of R014             | find.md         |
| R016 | find     | finding | high     | fixed                         | find.md         |
| R017 | find     | finding | high     | duplicate of R016             | find.md         |
| R018 | find     | finding | medium   | fixed                         | find.md         |
| R019 | find     | finding | medium   | fixed                         | find.md         |
| R020 | find     | finding | medium   | fixed                         | find.md         |
| R021 | find     | finding | medium   | fixed                         | find.md         |
| R022 | find     | finding | medium   | fixed                         | find.md         |
| R023 | find     | finding | medium   | fixed                         | find.md         |
| R024 | find     | finding | medium   | fixed                         | plugins-b-p2.md |
| R025 | find     | finding | medium   | fixed                         | find.md         |
| R026 | find     | finding | medium   | fixed                         | find.md         |
| R027 | find     | finding | medium   | fixed                         | find.md         |
| R028 | find     | finding | medium   | fixed                         | find.md         |
| R029 | find     | finding | medium   | fixed                         | find.md         |
| R030 | find     | finding | medium   | fixed                         | find.md         |
| R031 | find     | finding | medium   | fixed                         | find.md         |
| R032 | find     | finding | medium   | fixed                         | find.md         |
| R033 | find     | finding | medium   | duplicate of R022             | find.md         |
| R034 | find     | finding | medium   | duplicate of R025             | find.md         |
| R035 | find     | finding | medium   | fixed                         | find.md         |
| R036 | find     | finding | medium   | fixed                         | find.md         |
| R037 | find     | verdict | medium   | duplicate of R025             | find.md         |
| R038 | find     | verdict | medium   | duplicate of R022             | find.md         |
| R039 | find     | finding | medium   | duplicate of R025             | find.md         |
| R040 | find     | finding | medium   | duplicate of R025             | find.md         |
| R041 | find     | verdict | medium   | duplicate of R003             | find.md         |
| R042 | find     | verdict | medium   | duplicate of R012             | find.md         |
| R043 | find     | verdict | medium   | duplicate of R006             | find.md         |
| R044 | find     | verdict | medium   | duplicate of R012             | find.md         |
| R045 | find     | verdict | medium   | duplicate of R012             | find.md         |
| R046 | find     | finding | low      | fixed                         | find.md         |
| R047 | find     | finding | low      | fixed                         | find.md         |
| R048 | find     | finding | low      | duplicate of R025             | find.md         |
| R049 | find     | finding | low      | fixed                         | find.md         |
| R050 | find     | finding | low      | fixed                         | find.md         |
| R051 | find     | finding | low      | fixed                         | find.md         |
| R052 | find     | finding | low      | duplicate of R013             | find.md         |
| R053 | find     | finding | low      | fixed                         | find.md         |
| R054 | find     | finding | low      | fixed                         | find.md         |
| R055 | find     | finding | low      | fixed                         | find.md         |
| R056 | find     | finding | low      | fixed                         | find.md         |
| R057 | find     | finding | low      | fixed                         | find.md         |
| R058 | find     | finding | low      | fixed                         | find.md         |
| R059 | find     | finding | low      | fixed                         | find.md         |
| R060 | find     | finding | low      | fixed                         | find.md         |
| R061 | find     | finding | low      | fixed                         | find.md         |
| R062 | find     | finding | low      | fixed                         | find.md         |
| R063 | find     | finding | low      | fixed                         | find.md         |
| R064 | find     | finding | low      | fixed                         | find.md         |
| R065 | find     | finding | low      | fixed                         | find.md         |
| R066 | find     | finding | low      | fixed                         | find.md         |
| R067 | find     | finding | low      | fixed                         | find.md         |
| R068 | find     | verdict | low      | duplicate of R050             | find.md         |
| R069 | find     | verdict | low      | duplicate of R050             | find.md         |
| R070 | find     | verdict | low      | duplicate of R030             | find.md         |
| R071 | find     | finding | info     | not a defect                  | find.md         |
| R072 | find     | verdict | info     | refuted                       | find.md         |
| S001 | shell    | finding | high     | fixed                         | shell-p2.md     |
| S002 | shell    | finding | high     | fixed                         | shell.md        |
| S003 | shell    | finding | high     | fixed                         | shell.md        |
| S004 | shell    | finding | high     | fixed                         | shell-p2.md     |
| S005 | shell    | verdict | high     | fixed                         | shell.md        |
| S006 | shell    | finding | high     | fixed                         | shell.md        |
| S007 | shell    | finding | high     | fixed                         | shell.md        |
| S008 | shell    | finding | high     | fixed                         | shell.md        |
| S009 | shell    | finding | high     | fixed                         | shell.md        |
| S010 | shell    | finding | high     | fixed                         | shell.md        |
| S011 | shell    | finding | medium   | not a defect (here)           | shell-p2.md     |
| S012 | shell    | finding | medium   | fixed                         | shell.md        |
| S013 | shell    | finding | medium   | fixed                         | shell-p2.md     |
| S014 | shell    | finding | medium   | fixed                         | shell-p2.md     |
| S015 | shell    | finding | medium   | fixed                         | shell-p2.md     |
| S016 | shell    | finding | medium   | fixed                         | shell.md        |
| S017 | shell    | finding | medium   | fixed                         | shell.md        |
| S018 | shell    | finding | medium   | fixed                         | shell-p2.md     |
| S019 | shell    | verdict | medium   | fixed                         | shell.md        |
| S020 | shell    | finding | medium   | fixed                         | shell.md        |
| S021 | shell    | verdict | medium   | fixed                         | shell.md        |
| S022 | shell    | finding | medium   | fixed                         | shell.md        |
| S023 | shell    | finding | medium   | fixed                         | shell-p2.md     |
| S024 | shell    | verdict | medium   | fixed                         | shell-p2.md     |
| S025 | shell    | finding | medium   | fixed                         | shell.md        |
| S026 | shell    | finding | medium   | fixed                         | shell.md        |
| S027 | shell    | verdict | medium   | fixed                         | shell.md        |
| S028 | shell    | verdict | medium   | duplicate of S009             | shell.md        |
| S029 | shell    | verdict | medium   | duplicate of S025             | shell.md        |
| S030 | shell    | verdict | medium   | duplicate of S008             | shell.md        |
| S031 | shell    | finding | medium   | fixed                         | shell.md        |
| S032 | shell    | finding | medium   | duplicate of S010             | shell.md        |
| S033 | shell    | verdict | medium   | duplicate of S004             | shell-p2.md     |
| S034 | shell    | finding | medium   | fixed                         | shell-p2.md     |
| S035 | shell    | finding | low      | fixed                         | shell.md        |
| S036 | shell    | finding | low      | fixed                         | shell.md        |
| S037 | shell    | finding | low      | fixed                         | shell.md        |
| S038 | shell    | finding | low      | duplicate of S035             | shell.md        |
| S039 | shell    | finding | low      | fixed                         | shell-p2.md     |
| S040 | shell    | finding | low      | fixed                         | shell.md        |
| S041 | shell    | finding | low      | fixed                         | shell-p2.md     |
| S042 | shell    | finding | low      | fixed                         | shell-p2.md     |
| S043 | shell    | finding | low      | not a defect                  | shell-p2.md     |
| S044 | shell    | finding | low      | duplicate of S036             | shell.md        |
| S045 | shell    | finding | low      | fixed                         | shell.md        |
| S046 | shell    | finding | low      | fixed                         | shell.md        |
| S047 | shell    | finding | low      | fixed                         | shell.md        |
| S048 | shell    | finding | low      | fixed                         | shell-p2.md     |
| S049 | shell    | finding | low      | duplicate of S012             | shell.md        |
| S050 | shell    | finding | low      | fixed                         | shell.md        |
| S051 | shell    | verdict | low      | duplicate of S017             | shell.md        |
| S052 | shell    | finding | low      | fixed                         | shell.md        |
| S053 | shell    | finding | low      | fixed                         | shell.md        |
| S054 | shell    | verdict | low      | duplicate of S053             | shell.md        |
| S055 | shell    | finding | low      | fixed                         | shell-p2.md     |
| S056 | shell    | verdict | low      | refuted                       | shell.md        |
| S057 | shell    | verdict | low      | fixed                         | shell.md        |
| S058 | shell    | finding | low      | fixed                         | shell.md        |
| S059 | shell    | finding | low      | fixed                         | shell.md        |
| S060 | shell    | finding | low      | fixed                         | shell.md        |
| S061 | shell    | finding | low      | fixed                         | shell.md        |
| S062 | shell    | finding | low      | fixed                         | shell.md        |
| S063 | shell    | finding | low      | fixed                         | shell.md        |
| S064 | shell    | finding | low      | fixed                         | shell.md        |
| S065 | shell    | finding | low      | fixed                         | shell.md        |
| S066 | shell    | finding | low      | fixed                         | shell.md        |
| S067 | shell    | finding | low      | fixed                         | shell.md        |
| S068 | shell    | finding | low      | fixed                         | shell.md        |
| S069 | shell    | finding | low      | fixed                         | shell.md        |
| S070 | shell    | finding | low      | fixed                         | shell.md        |
| S071 | shell    | verdict | low      | duplicate of S033             | shell.md        |
| S072 | shell    | finding | low      | fixed                         | shell-p2.md     |
| S073 | shell    | finding | low      | fixed                         | shell.md        |
| T001 | tools    | finding | high     | fixed                         | tools.md        |
| T002 | tools    | finding | high     | fixed                         | tools.md        |
| T003 | tools    | finding | high     | fixed                         | tools.md        |
| T004 | tools    | verdict | high     | fixed                         | tools.md        |
| T005 | tools    | finding | high     | fixed                         | tools.md        |
| T006 | tools    | finding | high     | fixed                         | tools.md        |
| T007 | tools    | verdict | high     | fixed                         | tools.md        |
| T008 | tools    | finding | high     | fixed                         | tools.md        |
| T009 | tools    | verdict | high     | duplicate of T008             | tools.md        |
| T010 | tools    | finding | high     | fixed                         | tools.md        |
| T011 | tools    | verdict | high     | duplicate of T010             | tools.md        |
| T012 | tools    | finding | high     | fixed                         | tools.md        |
| T013 | tools    | verdict | high     | duplicate of T012             | tools.md        |
| T014 | tools    | finding | high     | fixed                         | tools.md        |
| T015 | tools    | verdict | high     | duplicate of T014             | tools.md        |
| T016 | tools    | finding | high     | fixed                         | tools.md        |
| T017 | tools    | verdict | high     | duplicate of T016             | tools.md        |
| T018 | tools    | finding | medium   | fixed                         | tools.md        |
| T019 | tools    | finding | medium   | fixed                         | tools.md        |
| T020 | tools    | finding | medium   | fixed                         | tools.md        |
| T021 | tools    | finding | medium   | fixed                         | tools.md        |
| T022 | tools    | finding | medium   | duplicate of T018             | tools.md        |
| T023 | tools    | finding | medium   | duplicate of T020             | tools.md        |
| T024 | tools    | finding | medium   | fixed                         | fileops-p2.md   |
| T025 | tools    | finding | medium   | fixed                         | plugins-b-p2.md |
| T026 | tools    | finding | medium   | fixed                         | plugins-b-p2.md |
| T027 | tools    | finding | medium   | fixed                         | tools.md        |
| T028 | tools    | finding | medium   | fixed                         | tools.md        |
| T029 | tools    | finding | medium   | fixed                         | plugins-b-p2.md |
| T030 | tools    | finding | medium   | duplicate of T018             | tools.md        |
| T031 | tools    | finding | medium   | fixed                         | tools.md        |
| T032 | tools    | verdict | medium   | duplicate of T003             | tools.md        |
| T033 | tools    | verdict | medium   | refuted                       | tools.md        |
| T034 | tools    | finding | medium   | duplicate of T004             | tools.md        |
| T035 | tools    | finding | medium   | fixed                         | tools.md        |
| T036 | tools    | verdict | medium   | fixed                         | tools.md        |
| T037 | tools    | finding | medium   | fixed                         | tools.md        |
| T038 | tools    | verdict | medium   | fixed                         | tools.md        |
| T039 | tools    | finding | medium   | fixed                         | tools.md        |
| T040 | tools    | finding | medium   | fixed                         | plugins-b-p2.md |
| T041 | tools    | finding | medium   | duplicate of T020             | tools.md        |
| T042 | tools    | finding | medium   | duplicate of T038             | tools.md        |
| T043 | tools    | finding | medium   | fixed                         | tools.md        |
| T044 | tools    | verdict | medium   | duplicate of T005             | tools.md        |
| T045 | tools    | finding | medium   | duplicate of T007             | tools.md        |
| T046 | tools    | finding | low      | fixed                         | tools.md        |
| T047 | tools    | finding | low      | fixed                         | fileops-p2.md   |
| T048 | tools    | finding | low      | fixed                         | tools.md        |
| T049 | tools    | finding | low      | fixed                         | tools.md        |
| T050 | tools    | finding | low      | fixed                         | plugins-b-p2.md |
| T051 | tools    | finding | low      | duplicate                     | plugins-b-p2.md |
| T052 | tools    | finding | low      | fixed                         | tools.md        |
| T053 | tools    | finding | low      | duplicate of T021             | tools.md        |
| T054 | tools    | finding | low      | fixed                         | tools.md        |
| T055 | tools    | finding | low      | duplicate of T046             | tools.md        |
| T056 | tools    | finding | low      | fixed                         | tools.md        |
| T057 | tools    | finding | low      | fixed                         | tools.md        |
| T058 | tools    | finding | low      | fixed                         | tools.md        |
| T059 | tools    | finding | low      | fixed                         | tools.md        |
| T060 | tools    | finding | low      | fixed                         | tools.md        |
| T061 | tools    | finding | low      | fixed                         | tools.md        |
| T062 | tools    | finding | low      | fixed                         | tools.md        |
| T063 | tools    | verdict | low      | refuted                       | tools.md        |
| T064 | tools    | finding | low      | fixed                         | tools.md        |
| T065 | tools    | verdict | low      | refuted                       | tools.md        |
| T066 | tools    | finding | low      | fixed                         | tools.md        |
| T067 | tools    | finding | low      | fixed                         | tools.md        |
| T068 | tools    | finding | low      | fixed                         | tools.md        |
| T069 | tools    | finding | low      | fixed                         | tools.md        |
| T070 | tools    | finding | low      | duplicate of T021             | tools.md        |
| T071 | tools    | finding | low      | fixed                         | tools.md        |
| T072 | tools    | finding | low      | fixed                         | tools.md        |
| T073 | tools    | finding | info     | fixed                         | tools.md        |
| T074 | tools    | finding | info     | not a defect                  | tools.md        |
| V001 | viewer   | finding | critical | fixed                         | viewer.md       |
| V002 | viewer   | finding | critical | fixed                         | viewer.md       |
| V003 | viewer   | finding | critical | fixed                         | viewer.md       |
| V004 | viewer   | finding | critical | duplicate of V001             | viewer.md       |
| V005 | viewer   | finding | high     | fixed                         | viewer.md       |
| V006 | viewer   | finding | high     | duplicate of V003             | viewer.md       |
| V007 | viewer   | finding | high     | fixed                         | viewer.md       |
| V008 | viewer   | finding | high     | duplicate of V007             | viewer.md       |
| V009 | viewer   | finding | high     | fixed                         | viewer.md       |
| V010 | viewer   | verdict | high     | fixed                         | viewer.md       |
| V011 | viewer   | finding | high     | duplicate of V001             | viewer.md       |
| V012 | viewer   | finding | high     | duplicate of V001             | viewer.md       |
| V013 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V014 | viewer   | verdict | medium   | fixed                         | viewer.md       |
| V015 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V016 | viewer   | verdict | medium   | fixed                         | viewer.md       |
| V017 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V018 | viewer   | verdict | medium   | fixed                         | viewer.md       |
| V019 | viewer   | finding | medium   | duplicate of V007             | viewer.md       |
| V020 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V021 | viewer   | finding | medium   | fixed                         | plugins-b-p2.md |
| V022 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V023 | viewer   | verdict | medium   | duplicate of V022             | viewer.md       |
| V024 | viewer   | finding | medium   | fixed                         | plugins-b-p2.md |
| V025 | viewer   | finding | medium   | duplicate of V010             | viewer.md       |
| V026 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V027 | viewer   | verdict | medium   | duplicate of V001             | viewer.md       |
| V028 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V029 | viewer   | finding | medium   | fixed                         | viewer.md       |
| V030 | viewer   | finding | medium   | fixed                         | plugins-b-p2.md |
| V031 | viewer   | finding | medium   | fixed                         | plugins-b-p2.md |
| V032 | viewer   | finding | low      | not a defect                  | viewer.md       |
| V033 | viewer   | finding | low      | fixed                         | viewer.md       |
| V034 | viewer   | finding | low      | fixed                         | plugins-b-p2.md |
| V035 | viewer   | finding | low      | fixed                         | plugins-b-p2.md |
| V036 | viewer   | finding | low      | fixed                         | viewer.md       |
| V037 | viewer   | finding | low      | not a defect                  | viewer.md       |
| V038 | viewer   | finding | low      | duplicate                     | plugins-b-p2.md |
| V039 | viewer   | finding | low      | duplicate of V021             | viewer.md       |
| V040 | viewer   | finding | low      | fixed                         | viewer.md       |
| V041 | viewer   | finding | low      | duplicate of V042             | viewer.md       |
| V042 | viewer   | finding | low      | fixed                         | viewer.md       |
| V043 | viewer   | finding | low      | fixed                         | viewer.md       |
| V044 | viewer   | finding | low      | fixed                         | viewer.md       |
| V045 | viewer   | finding | low      | fixed                         | viewer.md       |
| V046 | viewer   | finding | low      | fixed                         | viewer.md       |
| V047 | viewer   | verdict | low      | refuted                       | viewer.md       |
| V048 | viewer   | finding | low      | fixed                         | viewer.md       |
| V049 | viewer   | finding | low      | fixed                         | viewer.md       |
| V050 | viewer   | finding | low      | fixed                         | plugins-b-p2.md |
| V051 | viewer   | finding | low      | duplicate of V007             | viewer.md       |
| V052 | viewer   | finding | low      | fixed                         | viewer.md       |
| V053 | viewer   | finding | low      | duplicate of V052             | viewer.md       |
| V054 | viewer   | finding | low      | fixed                         | viewer.md       |
| V055 | viewer   | finding | low      | fixed                         | viewer.md       |
| V056 | viewer   | verdict | low      | duplicate of V021             | viewer.md       |
| V057 | viewer   | verdict | low      | duplicate of V009             | viewer.md       |
| V058 | viewer   | finding | low      | fixed                         | viewer.md       |
| V059 | viewer   | finding | low      | fixed                         | viewer.md       |
| V060 | viewer   | finding | low      | duplicate of V048             | viewer.md       |
| V061 | viewer   | finding | low      | fixed                         | viewer.md       |
| V062 | viewer   | finding | low      | fixed                         | viewer.md       |
| V063 | viewer   | finding | low      | fixed                         | viewer.md       |
| V064 | viewer   | finding | low      | fixed                         | viewer.md       |
| V065 | viewer   | finding | low      | fixed                         | viewer.md       |
| V066 | viewer   | finding | low      | fixed                         | viewer.md       |
| V067 | viewer   | finding | low      | fixed                         | viewer.md       |
| V068 | viewer   | finding | low      | fixed                         | viewer.md       |
| V069 | viewer   | finding | low      | fixed                         | plugins-b-p2.md |
| V070 | viewer   | finding | low      | fixed                         | fileops-p2.md   |
| V071 | viewer   | finding | low      | duplicate of V020             | viewer.md       |
| V072 | viewer   | finding | low      | duplicate of V040             | viewer.md       |
| V073 | viewer   | finding | low      | fixed                         | viewer.md       |
| V074 | viewer   | finding | low      | duplicate of V061             | viewer.md       |
| V075 | viewer   | finding | low      | duplicate of V024             | viewer.md       |
| V076 | viewer   | finding | low      | not a defect                  | viewer.md       |
| V077 | viewer   | finding | low      | not a defect                  | viewer.md       |
| V078 | viewer   | finding | low      | duplicate of V055             | viewer.md       |
| V079 | viewer   | finding | low      | fixed                         | plugins-b-p2.md |
| V080 | viewer   | finding | info     | not a defect                  | viewer.md       |
| V081 | viewer   | finding | info     | fixed                         | viewer.md       |
| V082 | viewer   | finding | info     | duplicate of V046             | viewer.md       |
| V083 | viewer   | finding | info     | fixed                         | viewer.md       |
| V084 | viewer   | finding | info     | fixed                         | viewer.md       |
| V085 | viewer   | finding | info     | duplicate of V043             | viewer.md       |
| V086 | viewer   | finding | info     | fixed                         | viewer.md       |
| V087 | viewer   | finding | info     | duplicate of V049             | viewer.md       |
| V088 | viewer   | finding | info     | duplicate of V046             | viewer.md       |
| V089 | viewer   | finding | info     | fixed                         | viewer.md       |
| V090 | viewer   | finding | info     | not a defect                  | viewer.md       |
| V091 | viewer   | finding | info     | not a defect                  | viewer.md       |
| X001 | tests    | finding | low      | fixed in part                 | shell-p2.md     |
| X002 | tests    | finding | low      | fixed in part                 | shell-p2.md     |
| X003 | tests    | finding | low      | fixed                         | plugins-b-p2.md |
| X004 | tests    | finding | low      | fixed                         | plugins-b-p2.md |
| X005 | tests    | finding | low      | fixed                         | shell-p2.md     |
| X006 | tests    | finding | low      | fixed                         | shell-p2.md     |
| X007 | tests    | finding | low      | fixed                         | plugins-b-p2.md |
| X008 | tests    | finding | low      | fixed                         | plugins-b-p2.md |
