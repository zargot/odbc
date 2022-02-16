when defined(windows):
  {.push stdcall.}
else:
  {.push cdecl.}

include std/odbcsql

{.push importc, dynlib: odbclib.}

proc SQLMoreResults*(StatementHandle: SqlHStmt): TSqlSmallInt

proc SQLGetTypeInfo*(StatementHandle: SqlHStmt,
    DataType: TSqlSmallInt): TSqlSmallInt
