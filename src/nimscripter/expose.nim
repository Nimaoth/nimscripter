import std/[macros, macrocache]
import compiler/[renderer, ast, vmdef, vm]
import procsignature
export VmProcSignature

func deSym*(n: NimNode): NimNode =
  # Remove all symbols
  result = n
  for x in 0 .. result.len - 1:
    if result[x].kind == nnkSym:
      result[x] = ident($result[x])
    else:
      result[x] = result[x].deSym

func getMangledName*(pDef: NimNode): string =
  ## Generates a close to type safe name for backers
  result = $pdef[0]
  for def in pDef[3][1..^1]:
    for idnt in def[0..^3]:
      result.add $idnt
    if def[^2].kind in {nnkSym, nnkIdent}:
      result.add $def[^2]
  result.add "Comp"

func getVmRuntimeImpl*(pDef: NimNode): string =
  ## Returns the nimscript code that will convert to string and return the value.
  ## This does the interop and where we want a serializer if we ever can.
  let deSymd = deSym(pDef.copyNimTree())
  deSymd[^1] = nnkDiscardStmt.newTree(newEmptyNode())

  result = deSymd.repr


proc getLambda*(pDef: NimNode): NimNode =
  ## Generates the lambda for the vm backed logic.
  ## This is what the vm calls internally when talking to Nim
  let
    vmArgs = ident"vmArgs"
    args = ident"args"
    pos = ident"pos"
    tmp = quote do:
      proc n(`vmArgs`: VmArgs){.closure, gcsafe.} = discard

  tmp[^1] = newStmtList()

  tmp[0] = newEmptyNode()
  result = nnkLambda.newNimNode()
  tmp.copyChildrenTo(result)

  var procArgs: seq[NimNode]
  for def in pDef.params[1..^1]:
    let typ = def[^2]
    for idnt in def[0..^3]: # Get data from buffer in the vm proc
      let 
        idnt = ident($idnt)
        argNum = procArgs.len
      procArgs.add idnt
      result[^1].add quote do:
        var `idnt` = fromVm(type(`typ`), getNode(`vmArgs`, `argNum`))
  if pdef.params.len > 1:
    result[^1].add newCall(pDef[0], procArgs)

const
  procedureCache = CacheTable"NimscriptProcedures"
  codeCache = CacheTable"NimscriptCode"

macro exportToScript*(moduleName: untyped, procedure: typed): untyped =
  result = procedure
  moduleName.expectKind(nnkIdent)
  block add:
    for name, _ in procedureCache:
      if name == $moduleName:
        procedureCache[name].add procedure
        break add
    procedureCache[$moduleName] = nnkStmtList.newTree(procedure)


func getVmStringImpl(pDef: NimNode): string =
  ## Takes a proc and changes the name to be manged for the string backend
  ## parameters are replaced with a single string, return value aswell.
  ## Hidden backed procedure for the Nim interop
  let deSymd = deSym(pdef.copyNimTree())
  deSymd[0] = ident(getMangledName(pDef))

  if deSymd.params.len > 2: # Delete all params but first/return type
    deSymd.params.del(2, deSymd[3].len - 2)

  if deSymd.params.len > 1: # Changes the first parameter to string named `parameters`
    deSymd.params[1] = newIdentDefs(ident("parameters"), ident("string"))

  if deSymd.params[0].kind != nnkEmpty: # Change the return type to string so can be picked up later
    deSymd.params[0] = ident("string")

  deSymd[^1] = nnkDiscardStmt.newTree(newEmptyNode())
  deSymd[^2] = nnkDiscardStmt.newTree(newEmptyNode())
  result = deSymd.repr

macro implNimscriptModule*(moduleName: untyped): untyped =
  moduleName.expectKind(nnkIdent)
  result = nnkBracket.newNimNode()
  for p in procedureCache[$moduleName]:
    let
      runImpl = getVmRuntimeImpl(p)
      lambda = getLambda(p)
      realName = $p[0]
    result.add quote do:
      VmProcSignature(
        name: `realName`,
        vmRunImpl: `runImpl`,
        vmProc: `lambda`
      )

proc fromVm*(t: typedesc[SomeOrdinal], node: PNode): t =
  assert node.kind in nkCharLit..nkUInt64Lit
  return node.intVal.t

proc fromVm*(t: typedesc[SomeFloat], node: PNode): t =
  assert node.kind in nkFloatLit..nkFloat128Lit, $node.kind
  node.floatVal.t

proc fromVm*(t: typedesc[string], node: PNode): string =
  assert node.kind == nkStrLit
  node.strVal


proc parseNode(vmNode, typ: NimNode): NimNode =
  let impl = typ.getImpl[^1][^1]
  result = newStmtList()
  var idents: seq[NimNode]
  for x in impl:
    if x.kind == nnkIdentDefs:
      let iTyp = x[^2]
      for obj in x[0..^3]:
        echo obj.treeRepr
        let
          name = obj.basename
          offset = idents.len + 1
        idents.add nnkExprColonExpr.newTree(name, name)
        result.add quote do:
          var `name` = fromVm(type(`iTyp`), `vmNode`[`offset`][1])
  result.add nnkObjConstr.newTree(typ)
  result[^1].add idents
  result = newBlockStmt(result)

macro fromVm*[T: object](obj: typedesc[T], vmNode: PNode): untyped =
  newStmtList(newCall(ident"privateAccess", obj[0]), vmNode.parseNode(obj[0]))