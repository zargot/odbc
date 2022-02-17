when defined(windows):
  {.push stdcall.}
else:
  {.push cdecl.}

include std/odbcsql

{.push importc, dynlib: odbclib.}

proc SQLDriverConnectW*(hdbc: SqlHDBC, hwnd: SqlHWND, szCsin: WideCString,
    szCLen: TSqlSmallInt, szCsout: WideCString, cbCSMax: TSqlSmallInt,
    cbCsOut: var TSqlSmallInt, f: SqlUSmallInt): TSqlSmallInt

proc SQLMoreResults*(StatementHandle: SqlHStmt): TSqlSmallInt

proc SQLGetTypeInfo*(StatementHandle: SqlHStmt,
    DataType: TSqlSmallInt): TSqlSmallInt
