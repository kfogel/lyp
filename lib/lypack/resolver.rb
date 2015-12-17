class Lypack::Resolver
  def initialize(user_file)
    @user_file = user_file
  end
  
  def resolve_package_dependencies
    tree = process
    resolve_tree(tree)
  end
  
  DEP_RE = /\\(require|include) "([^"]+)"/.freeze
  INCLUDE = "include".freeze
  REQUIRE = "require".freeze
  
  # Process a user file and return a dependency tree
  def process
    tree = {
      dependencies: {},
      queue: [],
      processed_files: {}
    }
    
    queue_file_for_processing(@user_file, tree, tree)

    while job = pull_file_from_queue(tree)
      process_lilypond_file(job[:path], tree, job[:ptr])
    end
    
    remove_unfulfilled_dependencies(tree)
    
    tree
  end
  
  def process_lilypond_file(path, tree, ptr)
    # path is expected to be absolute
    return if file_processed?(path, tree)
    
    ly_content = IO.read(path)
    dir = File.dirname(path)
    
    ly_content.scan(DEP_RE) do |type, path|
      case type
      when INCLUDE
        qualified_path = File.expand_path(path, dir)
        queue_file_for_processing(qualified_path, tree, ptr)
      when REQUIRE
        find_package_versions(path, tree, ptr)
      end
    end
    
    tree[:processed_files][path] = true
  end
  def file_processed?(path, tree)
    tree[:processed_files][path]
  end
  
  def queue_file_for_processing(path, tree, ptr)
    (tree[:queue] ||= []) << {path: path, ptr: ptr}
  end
  
  def pull_file_from_queue(tree)
    tree[:queue].shift
  end
  
  PACKAGE_RE = /^([^@]+)(?:@(.+))?$/
  
  def find_package_versions(ref, tree, ptr)
    return {} unless ref =~ PACKAGE_RE
    ref_package = $1
    version_clause = $2

    matches = find_matching_packages(ref, tree)
    
    if matches.empty? && (tree == ptr)
      raise "No package found for requirement #{ref}"
    end
    
    # Make sure found packages are processed
    matches.each do |p, subtree|
      if subtree[:path]
        queue_file_for_processing(subtree[:path], tree, subtree)
      end
    end
    
    (ptr[:dependencies] ||= {}).merge!({
      ref_package => {
        clause: ref,
        versions: matches
      }
    })
  end
  
  def find_matching_packages(ref, tree)
    return {} unless ref =~ PACKAGE_RE
    
    ref_package = $1
    version_clause = $2
    req = Gem::Requirement.new(version_clause || '>=0')

    available_packages(tree).select do |package_name, sub_tree|
      if package_name =~ PACKAGE_RE
        version = Gem::Version.new($2 || '0')
        (ref_package == $1) && (req =~ version)
      else
        nil
      end
    end
  end
  
  MAIN_PACKAGE_FILE = 'package.ly'
  
  def available_packages(tree)
    tree[:available_packages] ||= get_available_packages(Lypack.packages_dir)
  end
  
  def get_available_packages(dir)
    Dir["#{Lypack.packages_dir}/*"].inject({}) do |m, p|
      m[File.basename(p)] = {
        path: File.join(p, MAIN_PACKAGE_FILE), 
        dependencies: {},
        
      }
      m
    end
  end

  # Recursively remove any dependency for which no version is locally 
  # available. If no version is found for any of the dependencies specified
  # by the user, an error is raised.
  # 
  # The processed hash is used for keeping track of dependencies that were
  # already processed, and thus deal with circular dependencies.
  def remove_unfulfilled_dependencies(tree, raise_on_missing = true, processed = {})
    return unless tree[:dependencies]
    
    tree[:dependencies].each do |package, dependency|
      dependency[:versions].select! do |version, version_subtree|
        if processed[version]
          true
        else
          processed[version] = true

          remove_unfulfilled_dependencies(version_subtree, false, processed)
          valid = true
          version_subtree[:dependencies].each do |k, v|
            valid = false if v[:versions].empty?
          end
          valid
        end
      end
      raise if dependency[:versions].empty? && raise_on_missing
    end
  end
  
  def resolve_tree(tree)
    permutations = permutate_simplified_tree(tree)
    permutations = filter_invalid_permutations(permutations)

    user_deps = tree[:dependencies].keys
    result = select_highest_versioned_permutation(permutations, user_deps).flatten
    
    if result.empty? && !tree[:dependencies].empty?
      raise "Failed to satisfy dependency requirements"
    else
      result
    end
  end
  
  def remove_unfulfilled_dependency_versions(tree, raise_on_missing_versions = true)
    return unless tree[:dependencies]
    
    tree[:dependencies].select! do |k, subtree|
      if subtree[:versions]
        subtree[:versions].each do |v, vsubtree|
          remove_unfulfilled_dependency_versions(vsubtree, false)
        end
        true
      else
        raise if raise_on_missing_versions
        false
      end
    end
  end
  
  def permutate_simplified_tree(tree)
    deps = dependencies_array(simplified_deps_tree(tree))
    return deps if deps.empty?

    # Return a cartesian product of dependencies
    deps[0].product(*deps[1..-1]).map(&:flatten)
  end
  
  def dependencies_array(tree, processed = {})
    return processed[tree] if processed[tree]

    deps_array = []
    processed[tree] = deps_array
    
    tree.each do |pack, versions|
      a = []
      versions.each do |version, deps|
        perms = []
        sub_perms = dependencies_array(deps, processed)
        if sub_perms == []
          perms += [version]
        else
          sub_perms[0].each do |perm|
            perms << [version] + [perm].flatten
          end
        end
        a += perms
      end
      deps_array << a
    end

    deps_array
  end
  
  # The processed hash is used to deal with circular dependencies
  def simplified_deps_tree(version, processed = {})
    return {} unless version[:dependencies]
    
    return processed[version] if processed[version]
    processed[version] = dep_versions = {}

    # For each dependency, generate a deps tree for each available version
    version[:dependencies].each do |p, subtree|
      dep_versions[p] = {}
      subtree[:versions].each do |v, version_subtree|
        dep_versions[p][v] = 
          simplified_deps_tree(version_subtree, processed)
      end
    end

    dep_versions
  end
  
  def filter_invalid_permutations(permutations)
    valid = []
    permutations.each do |perm|
      versions = {}; invalid = false
      perm.each do |ref|
        if ref =~ /(.+)@(.+)/
          name, version = $1, $2
          if versions[name] && versions[name] != version
            invalid = true
            break
          else
            versions[name] = version
          end
        end
      end
      valid << perm.uniq unless invalid
    end

    valid
  end
  
  def select_highest_versioned_permutation(permutations, user_deps)
    sorted = sort_permutations(permutations, user_deps)
    sorted.empty? ? [] : sorted.last
  end
  
  PACKAGE_REF_RE = /^([^@]+)(?:@(.+))?$/
  
  def sort_permutations(permutations, user_deps)
    map = lambda do |m, p|
      if p =~ PACKAGE_REF_RE
        m[$1] = Gem::Version.new($2 || '0.0')
      end
      m
    end
    
    compare = lambda do |x, y|
      x_versions = x.inject({}, &map)
      y_versions = y.inject({}, &map)
      
      # Naive implementation - add up the comparison scores for each package
      x_versions.keys.inject(0) do |s, k|
        cmp = x_versions[k] <=> y_versions[k]
        s += cmp unless cmp.nil?
        s
      end
    end
    
    permutations.sort(&compare)
  end  
end
  
