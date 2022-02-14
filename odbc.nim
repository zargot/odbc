# "Microsoft is adopting ODBC as the de-facto standard for native access to SQL Server and Windows Azure SQL Database."
#
# A note on this library's performance:
# See: https://msdn.microsoft.com/en-us/library/ms131269.aspx
# "If a result set contains only a few rows, using SQLGetData instead of SQLBindCol is faster;
# otherwise, SQLBindCol gives the best performance."
# SQLGetData, however, makes for easier fetching of variable sized large data, such as images
# or text data. Note that it is possible to use both functions in one query, so it may make
# sense to SQLBindCol simple types and SQLGetData larger, variable types in future.

import
  odbcsql,
  times,
  tables,
  typetraits,
  strutils

when defined(odbcdebug):
  import strformat

import
  odbc/[
    odbctypes,
    odbcerrors,
    odbcreporting,
    odbcconnections,
    odbcfields,
    odbchandles,
    odbcparams,
    odbcjson,
    odbcutils]

export odbctypes, odbcreporting, odbcerrors, odbcconnections, odbcfields, odbcjson, odbcutils
export odbcparams except readFromBuf, writeToBuf, bindParams

type
  SQLQueryObj* = object
    handle: SqlHStmt
    # statement is handled by a property getter/setter as setting the statement
    # triggers a search for parameters
    fStatement: string
    # This is the statement with "?name" replaced with "?" (ODBC doesn't allow named parameters)
    # odbcStatement is set up when the statement is set
    fOdbcStatement: string
    # metadata for result columns
    colFields: seq[SQLField]
    # dataBuf is the default buffer for reading data from ODBC for processing
    dataBuf: pointer
    # only accessible with read proc
    opened: bool
    con*: ODBCConnection
    # int indexed seq
    params*: SQLParams
    # lower case fieldname to seq index hash table
    fieldIdxs: FieldIdxs
    # whether to prepare the query, true by default.
    prepare*: bool

  # Main query object
  SQLQuery* = ref SQLQueryObj

proc freeQuery*(qry: SQLQuery) =
  # finalizer for query
  when defined(odbcdebug): echo &"Freeing query with handle {qry.handle}"
  freeStatementHandle(qry.handle, qry.con.reporting)
  qry.handle = nil
  qry.params.clear
  if qry.dataBuf != nil:
    dealloc(qry.dataBuf)
    qry.dataBuf = nil

proc newQuery*(con: ODBCConnection): SQLQuery =
  when defined(odbcFinalizers):
    new(result, freeQuery)
  else:
    new(result)
  result.con = con
  result.params = initParams()
  result.colFields = @[]
  result.prepare = true
  result.fieldIdxs = initFieldIdxs()

# read only access to statement handle
proc statementHandle*(qry: SQLQuery): SqlHStmt = qry.handle

proc columnCount*(qry: SQLQuery): int =
  var r: TSqlSmallInt
  rptOnErr(qry.con.reporting, SQLNumResultCols(qry.handle, r), "Get Column Count", qry.handle)
  result = r

proc fields*(qry: SQLQuery, fieldname: string): SQLField =
  ## Accessor for getting the column index of a field by name.
  ## This is accessible after the query has been opened and is performed as a hash table lookup.
  let fieldLower = toLowerAscii(fieldname)
  if qry.fieldIdxs.hasKey(fieldLower): result = qry.colFields[qry.fieldIdxs[fieldLower]]
  else:
    raise newODBCUnknownFieldException("field \"" & $fieldlower & "\" not found in results")

proc fields*(qry: SQLQuery, idx: int): SQLField =
  ## Accessor for getting the column index of a field by name.
  ## This is accessible after the query has been opened and is performed as a hash table lookup.
  if idx < qry.colFields.len: 
    result = qry.colFields[idx]
  else:
    raise newODBCUnknownFieldException("field \"" & $idx & "\" out of range")

proc fieldIndex*(qry: SQLQuery, fieldname: string): int =
  ## Accessor for getting the column index of a field by name.
  ## This is accessible after the query has been opened and is performed as a hash table lookup.
  let fieldLower = toLowerAscii(fieldname)
  if qry.fieldIdxs.hasKey(fieldLower): result = qry.fieldIdxs[fieldLower]
  else:
    raise newODBCUnknownFieldException("field \"" & $fieldlower & "\" not found in results")

proc fetchRow*(qry: SQLQuery, row: var SQLRow): bool =
  ## Fetch a single row from an opened query.
  ## Returns true when more data exists, enabling use as a while proc:
  ##   while qry.fetchRow(row):
  # fetchRow currently uses a single buffer for every field that is cleared each time.
  # TODO: Support an option to allocate a buffer for each field and bind it so ODBC can write it directly.
  # This would use more memory but be slightly faster.
  row = initSQLRow()
  # Checking for a result set: https://msdn.microsoft.com/en-us/library/ms711684(v=vs.85).aspx
  # SQLRowCount returns something driver specific so we can't use that.
  # MS recommends checking column count.
  if not qry.opened:
    raise newODBCException("Attempt to fetch row on unopened query")

  let colCount = qry.columnCount
  if colCount == 0:
    return # no columns == no results

  var res = SQLFetch(qry.handle)

  result = res.sqlSucceeded and res != SQL_NO_DATA
  if res != SQL_NO_DATA:
    rptOnErr(qry.con.reporting, res, "Fetch", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)

  if result:
    for colIdx in 1..colCount:
      var
        colDetail = qry.colFields[colIdx - 1]
        size: int
      if colDetail.colType.isString:
        colDetail.sqlType = SQL_WCHAR
        # Add a space for zero terminator and account for WideChar
        size = (colDetail.size + 1) * 2
      else:
        size = colDetail.size

      size += 4 # Padding

      if size > sqlDefaultBufferSize:
        # size of column is larger than the default buffer size. Realloc to fit.
        when defined(odbcdebug): echo &"Increasing buffer size from default of {sqlDefaultBufferSize} to {size}"
        qry.dataBuf.dealloc
        qry.dataBuf = alloc0(size + 4)

      # clear buffer
      qry.dataBuf.zeroMem(size)

      when defined(odbcdebug): echo &"Fetching: {colDetail.colType}, sql type: {colDetail.sqlType} ctype {colDetail.ctype} size {size} colSize {colDetail.size}"

      var indicator: TSqlLen  # buffer
      res = SQLGetData( qry.handle, colIdx.SqlUSmallInt, colDetail.cType,
                        qry.dataBuf, size.TSqlLen, addr(indicator))
      rptOnErr(qry.con.reporting, res, "SQLGetData", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)
      when defined(odbcdebug): echo &"SQLGetData returned {res}, with indicator: {indicator}"

      # handle variable size data
      if res == SQL_SUCCESS_WITH_INFO:
        if indicator != SQL_NO_TOTAL and indicator != SQL_NULL_DATA:
          let total = indicator
          let retrieved = size
          let rem = total - retrieved
          let actualSize = total
          qry.dataBuf = realloc(qry.dataBuf, actualSize)
          let p = cast[pointer](cast[uint](qry.dataBuf) + size.uint)
          res = SQLGetData(qry.handle, colIdx.SqlUSmallInt, colDetail.cType,
                           p, rem, addr(indicator))
          rptOnErr(qry.con.reporting, res, "SQLGetData", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)
          when defined(odbcdebug): echo &"SQLGetData returned {res}, with indicator: {indicator}"
          indicator = actualSize

      if indicator == SQL_NO_TOTAL:
        when defined(odbcdebug): echo "No Total"
        else: discard
      else:
        if indicator != SQL_NULL_DATA:
          if res.sqlSucceeded:
            var curData = initSQLData(colDetail.colType.toDataType)
            # read data for current row
            curData.readFromBuf(qry.dataBuf, indicator)
            # we cannot know the tablename unfortunately
            row.add(curData)
        else:
          row.add(initSQLData(dtNull))

proc fetch*(qry: SQLQuery): SQLResults =
  ## Return all rows to results
  result = initSQLResults()
  result.fieldnameIndex = qry.fieldIdxs
  # copy over fields as they'll be the same as the query
  # Note that colIndex should already be set up and match our result columns
  result.colFields = qry.colFields
  var newRow = initSQLRow()
  while qry.fetchRow(newRow):
    result.add(newRow)

proc close*(qry: var SQLQuery) =
  ## Close a query. This does nothing if the query is already closed.
  # clean up
  # we don't necessarily want the parameters cleared here,
  # as you may simply wish to set them and re-run the query
  if qry.opened:
    # SQLFreeStmt*(StatementHandle: SqlHStmt, Option: SqlUSmallInt): TSqlSmallInt
    let res = SQLFreeStmt(qry.handle, SQL_CLOSE)
    rptOnErr(qry.con.reporting, res, "Close query (SQLFreeStmt)", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)
    qry.opened = false

proc `statement=`*(qry: var SQLQuery, statement: string) =
  ## Setting a statement closes a query if it's open, and rebuilds all parameters.
  # do not want changing the statement while a query is open,
  # as this would alter the parameters and get confusing
  # we DO want to clear the parameters here
  if qry.opened: qry.close  # this will also handle clearing of buffers, but not clear params
  qry.fStatement = statement
  qry.params.setupParams(qry.fStatement)
  qry.fOdbcStatement = qry.fStatement.odbcParamStatement

proc statement*(qry: var SQLQuery): string =
  ## Read current statement from query.
  qry.fStatement

proc odbcStatement*(qry: var SQLQuery): string =
  ## Read current statement as ODBC sees it. Named parameters are replaced with `?`.
  qry.fOdbcStatement

proc newQuery*(con: ODBCConnection, statement: string): SQLQuery =
  result = con.newQuery
  result.statement = statement

import macros

macro dbq*(con: ODBCConnection, queryText: string, params: varargs[tuple[name: string, value: untyped]]): untyped =
  ## Allows disposable queries that return results then free themselves.
  ## eg;
  ## `let tabData = connnections.dbq("SELECT * FROM table WHERE field = ?value", ("field", someValue))`
  let query = genSym(nskVar, "query")
  var paramUpdates = newStmtList()
  for param in params:
    let
      key = param[0]
      value = param[1]
    paramUpdates.add(quote do:
      `query`.params[`key`] = `value`)
  
  quote do:
    block:
      var
        r: SQLResults
        `query` = `con`.newQuery(`queryText`)
      try:
        `paramUpdates`
        r = `query`.executeFetch
      finally:
        `query`.freeQuery
      r

template setup(qry: var SQLQuery) =
  # if not already set up, allocates memory and a new statement handle
  if qry.dataBuf == nil:
    qry.dataBuf = alloc0(sqlDefaultBufferSize)
  if qry.handle == nil:
    qry.handle = newStatementHandle(qry.con.conHandle, qry.con.reporting)

template bindParams(qry: var SQLQuery) =
  # in place substitution for a bit less typing
  #apache drill has no concept of parameters so we resolve them before sending query
  if qry.con.serverType == ApacheDrill:
    qry.fOdbcStatement.bindParams(qry.params, qry.con.reporting)
  else:
    qry.handle.bindParams(qry.params, qry.con.reporting)

proc getColDetails(qry: SQLQuery, colID: int): SQLField =
  # get a column's metadata
  result = newSQLField(colIndex = colID - 1)  # also set up column index
  const buflen: TSqlSmallInt = 256
  var
    colName: string = newString(buflen)
    nameLen: TSqlSmallInt
    sqlDataType: TSqlSmallInt
    columnSize: TSqlULen
    decimalDigits: TSqlSmallInt
    nullable: TSqlSmallInt
    retval = SQLDescribeCol(qry.handle, colID.TSqlSmallInt, colName.cstring, buflen, nameLen, sqlDataType, columnSize, decimalDigits, nullable)

  rptOnErr(qry.con.reporting, retval, "SQLDescribeCol", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)
  colName.setLen(nameLen)

  if sqlSucceeded(retval):
    result.fieldName = colName
    result.colType = toSQLColumnType(sqlDataType)
    result.dataType = toDataType(result.colType)
    result.sqlType = sqlDataType
    result.size = columnSize.int
    result.digits = decimalDigits
    result.nullable = nullable != 0
    result.cType = result.colType.toCType

proc setupColumns(qry: var SQLQuery) =
  # get all column metadata details
  let
    columns = qry.columnCount

  qry.colFields.setLen(columns)
  for colIdx in 1..columns:
    qry.colFields[colIdx - 1] = getColDetails(qry, colIdx)

  # set up hash table of field names -> rows
  for idx, col in qry.colFields:
    qry.fieldIdxs[toLowerAscii(col.fieldName)] = idx

proc opened*(qry: SQLQuery): bool = qry.opened

template openInternal(qry: var SQLQuery): TSqlSmallInt =
  # returns the result of the last SQL (for checking for errors)
  qry.setup
  qry.opened = true

  var res: TSqlSmallInt

  if qry.prepare:
    # variables bound before prepare may allow query plans to be influenced by their content
    res = SQLPrepareW(qry.handle, newWideCString(qry.odbcStatement), SQL_NTS)  # worth passing len or let SQL do it?
    rptOnErr(qry.con.reporting, res, "Prepare Query, SQLPrepare", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)

    qry.bindParams
    res = SQLExecute(qry.handle)
    rptOnErr(qry.con.reporting, res, "Open Query, SQLExecute", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)
  else:
    qry.bindParams
    res = SQLExecDirectW(qry.handle, newWideCString(qry.odbcStatement), SQL_NTS)
    rptOnErr(qry.con.reporting, res, "Direct Open SQLExecuteDirect", qry.handle, SQL_HANDLE_STMT.TSqlSmallInt)
  # read column info
  qry.setupColumns
  res

proc open*(qry: var SQLQuery) =
  discard qry.openInternal

proc executeFetch*(qry: var SQLQuery): SQLResults =
  ## Prepare, open and fetch all results of query and place in result seq.
  var res = qry.openInternal
  try:
    # Note: SQLExecute/SQLExecuteDirect SHOULD return SQL_NO_DATA when no results are available.
    # However, it doesn't seem reliable. The check is here nevertheless, assuming the ODBC driver
    # behaves. See the fetchRow proc for the reliable method to check for a results set.
    if res.sqlSucceeded and res != SQL_NO_DATA:
      # read column info and collect all results
      qry.setupColumns
      result = fetch(qry)
    else:
      result = initSQLResults()
  finally:
    qry.close

proc executeFetch*(con: ODBCConnection, sql: string): SQLResults =
  var query = con.newQuery(sql)
  try:
    result = query.executeFetch
  finally:
    query.freeQuery

proc execute*(qry: var SQLQuery) =
  ## Execute query and ignore results.
  # ignores results from query, for resultless SQL
  try:
    qry.open
  finally:
    qry.close

template withExecute*(qry: SQLQuery, row, actions: untyped) =
  ## Execute query and perform block for each row returned.
  ## Query is automatically closed after the last row is read.
  qry.open
  try:
    var
      row {.inject.}: SQLRow
    while qry.fetchRow(row):
      actions
  finally:
    qry.close

template withExecuteByField*(qry: SQLQuery, actions: untyped) =
  ## Execute query and perform block for each field returned.
  ## Query is automatically closed after the last row is read.
  ## Injects
  ##  row: all field data in this row
  ##  field: current field object being processed
  ##  fieldIdx: index into qry.fields
  ##  data: data stored in this row's field
  qry.open
  try:
    var
      row {.inject.}: SQLRow
      field {.inject.}: SQLField
      fieldIdx {.inject.}: int
      data {.inject.}: SQLData
    while qry.fetchRow(row):
      for idx, item in row:
        fieldIdx = idx
        field = qry.fields(idx)
        data = item
        actions
  finally:
    qry.close

