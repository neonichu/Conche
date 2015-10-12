import Foundation
import PathKit

public struct GitSource {
  public let uri:String
  public let tag:String
}

public struct TestSpecification {
  public let sourceFiles:[String]
  public let dependencies:[Dependency]

  public init(spec:[String:AnyObject]) throws {
    self.sourceFiles = try parseSourceFiles(spec["source_files"])
    self.dependencies = parseDependencies(spec["dependencies"] as? [String:[String]] ?? [:])
  }
}

public struct Specification {
  public let name:String
  public let version:String

  // TODO Make source a protocol and support others
  public let source:GitSource?
  public let sourceFiles:[String]
  public let dependencies:[Dependency]
  public let entryPoints:[String:[String:String]]

  public let testSpecification:TestSpecification?

  public init(name:String, version:String) {
    self.name = name
    self.version = version
    self.source = nil
    self.sourceFiles = []
    self.dependencies = []
    self.entryPoints = [:]
    self.testSpecification = nil
  }
}


func parseDependencies(dependencies:[String:[String]]) -> [Dependency] {
  return dependencies.map { (name, requirements) in
    Dependency(name: name, requirements: requirements)
  }
}

func parseSource(source:[String:String]?) -> GitSource? {
  if let source = source, git = source["git"], tag = source["tag"] {
    return GitSource(uri: git, tag: tag)
  }

  return nil
}

enum SpecificationError : ErrorType {
  case MissingField(String)
  case IncorrectType(key: String)
  case Unsupported(String)
}

func validate<T>(source:[String:AnyObject], _ key:String) throws -> T {
  if let value = source[key] {
    if let value = value as? T {
      return value
    }

    throw SpecificationError.IncorrectType(key: key)
  }

  throw SpecificationError.MissingField(key)
}

extension Specification {
  public init(representation: [String:AnyObject]) throws {
    name = try validate(representation, "name")
    version = try validate(representation, "version")
    sourceFiles = try parseSourceFiles(representation["source_files"])
    dependencies = parseDependencies(representation["dependencies"] as? [String:[String]] ?? [:])
    entryPoints = representation["entry_points"] as? [String:[String:String]] ?? [:]
    source = parseSource(representation["source"] as? [String:String])

    if let testSpecification = representation["test_spec"] as? [String:AnyObject] {
      self.testSpecification = try TestSpecification(spec: testSpecification)
    } else {
      self.testSpecification = nil
    }

    if representation.keys.contains("subspecs") {
      throw SpecificationError.Unsupported("subspecs")
    }
  }

  public init(path:Path) throws {
    let data = try NSJSONSerialization.JSONObjectWithData(try path.read(), options: NSJSONReadingOptions(rawValue: 0))
    if let data = data as? [String:AnyObject] {
      try self.init(representation: data)
    } else {
      throw Error("Podspec does not contain a dictionary.")
    }
  }
}

func parseSourceFiles(sourceFiles: Any?) throws -> [String] {
  if let sourceFile = sourceFiles as? String {
    return [sourceFile]
  } else if let sourceFiles = sourceFiles as? [String] {
    return sourceFiles
  }

  return []
}


struct Error : ErrorType {
  let message:String

  init(_ message:String) {
    self.message = message
  }
}


/// Finds a podspec in the current working directory
public func findPodspec() throws -> Specification {
  let paths = try Path.current.children().filter { $0.description.hasSuffix("podspec.json") }
  if paths.count > 1 {
    let podspecs = paths.map { $0.lastComponent }.joinWithSeparator(", ")
    throw Error("Too many podspecs we're found: \(podspecs)")
  } else if let path = paths.first {
    return try Specification(path: path)
  } else {
    throw Error("There are no JSON podspecs in the current working directory.")
  }
}


extension Specification {
  public func build(source:Path, destination:Path) throws {
    var sourceFiles = self.sourceFiles.reduce([Path]()) { (accumulator, file) in
      let files = source.glob(file)
      return accumulator + files
    }

    sourceFiles = sourceFiles.filter { $0.`extension` != "h" }  // Discard headers

    for file in sourceFiles {
      if file.`extension` != "swift" {
        throw Error("Unsupported source file extension \(file.`extension`)")
      }
    }

    let source = sourceFiles.map { $0.description }.joinWithSeparator(" ")
    let libraries = dependencies.map { "-l\($0.name)" }.joinWithSeparator(" ")

    let libdir = destination + "lib"
    if !libdir.exists {
      try libdir.mkdir()
    }
    let library = libdir + "lib\(name).dylib"
    let moduledir = destination + "modules"
    if !moduledir.exists {
      try moduledir.mkdir()
    }
    let module = moduledir + "\(name).swiftmodule"

    // TODO, respect specifications module name
    // TODO support spec's frameworks
    try swiftc(["-I", moduledir.description, "-L", libdir.description, libraries, "-module-name", name, "-emit-library", "-emit-module", "-emit-module-path", module.description, source, "-o", library.description])
  }
}

