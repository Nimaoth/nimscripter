include compiler/nimeval

proc config*(i: Interpreter): ConfigRef = i.graph.config