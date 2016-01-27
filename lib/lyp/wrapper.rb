require 'tempfile'

module Lyp
  WRAPPER_TEMPLATE = Lyp::Template.new(IO.read(
    File.expand_path('templates/deps_wrapper.rb', File.dirname(__FILE__))
  ))
  
  def self.wrap(fn, opts = {})
    r = Lyp::Resolver.new(fn).resolve_package_dependencies

    if !r[:package_paths].empty? || opts[:force_wrap]
      FileUtils.mkdir_p('/tmp/lyp/wrappers')
      fn = "/tmp/lyp/wrappers/#{File.basename(fn)}" 
  
      File.open(fn, 'w+') {|f| f << WRAPPER_TEMPLATE.render(r)}
    end
    fn
  end
end