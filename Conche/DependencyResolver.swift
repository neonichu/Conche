/// Resolves a dependency with the given sources and returns
/// a dependency graph of resolved dependencies
public func resolve(dependency: Dependency, sources: [SourceType]) throws -> DependencyGraph {
  return try resolve(dependency, sources: sources, dependencies: [], resolveTestSpecifications: true)
}

/// Resolve a dependency with the given sources, iteratively
/// adding all known dependencies from previous resolutions
/// in the dependency tree, returning the collection of resolved
/// specifications
public func resolve(dependency: Dependency, sources: [SourceType], dependencies: [Dependency], resolveTestSpecifications: Bool = false) throws -> DependencyGraph {
  var specifications = search(dependency.combine(dependencies.filter { $0.name == dependency.name }), sources: sources)
  while let specification = specifications.popFirst() {
    do {
      let duplicates = dependencies.filter { $0 == dependency }
      if duplicates.count > 1 {
        throw DependencyResolverError.CircularDependency(specification.name, requiredBy: dependencies)
      }
      var specificationDependencies = specification.dependencies
      if resolveTestSpecifications, let testDependencies = specification.testSpecification?.dependencies {
        specificationDependencies += testDependencies
      }
      let resolution: [DependencyGraph] = try specificationDependencies.map {
        let specDeps = dependencies + specification.dependencies
        return try resolve($0, sources: sources, dependencies: specDeps)
      }.sort().uniq()
      let graph = DependencyGraph(root: specification, dependencies: resolution)
      if graph.hasCircularReference() {
        let specs = graph.flatten()
        let cycle = try specs.map { try Dependency(specification: $0) }
        throw DependencyResolverError.CircularDependency(specification.name, requiredBy: cycle)
      }
      return graph
    } catch let error as DependencyResolverError {
      if specifications.isEmpty {
        throw error
      }
    }
  }
  throw searchForConflict(dependency, sources: sources, dependencies: dependencies)
}

/// Searches available sources for dependencies, filtering out
/// pre-release versions if not explicitly requested
private func search(dependency: Dependency, sources: [SourceType]) -> ArraySlice<Specification> {
  for source in sources {
    var specifications = source.search(dependency).sort()
    if !specifications.isEmpty {
      if !dependency.usePreRelease() {
        specifications = specifications.removePreReleases()
      }
      return specifications[0..<specifications.endIndex]
    }
  }

  return []
}

/// Search available sources for dependencies, which are used
/// to correctly identify a pre-existing issue. If any found,
/// returns a conflict, otherwise 'no such dependency'.
private func searchForConflict(dependency: Dependency, sources: [SourceType], dependencies: [Dependency]) -> DependencyResolverError {
  let incompatible = search(dependency, sources: sources)
  if incompatible.count > 0 {
    return DependencyResolverError.Conflict(dependency.name, requiredBy: dependencies)
  }
  return DependencyResolverError.NoSuchDependency(dependency)
}

extension CollectionType where Generator.Element == Specification {
  /// Filters specifications removing pre-release versions
  func removePreReleases() -> [Generator.Element] {
    return filter { $0.version.prerelease == nil }
  }

  func uniq() -> [Generator.Element] {
    var seen: [String: Bool] = [:]
    return filter { seen.updateValue(true, forKey: $0.description) == nil }
  }

  /// Sorts specifications by name and version, highest first
  func sort() -> [Generator.Element] {
    return sort { $0.name >= $1.name && $0.version >= $1.version }
  }
}

extension Dependency {
  /// Creates a dependency using the name and exact version of a
  /// specification
  init(specification: Specification) throws {
    self.name = specification.name
    self.requirements = try [Requirement(specification.version.description)] ?? []
  }

  func combine(dependencies: [Dependency]) -> Dependency {
    let reqs = dependencies.map { $0.requirements }.reduce(requirements, combine: +)
    return Dependency(name: name, requirements: reqs)
  }

  /// Flag to determine whether to use pre-release versions of
  /// specifications
  func usePreRelease() -> Bool {
    return requirements.contains { $0.version.prerelease != nil }
  }

  /// returns true if a specification cannot satisfy the dependency
  func incompatible(specification: Specification) -> Bool {
    return !satisfies(specification.version) || (!usePreRelease() && specification.version.prerelease != nil)
  }
}
