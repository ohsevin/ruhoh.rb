module Ruhoh::Resources
  class Posts < Resource
    
    def config
      hash = super
      hash['permalink'] ||= "/:categories/:year/:month/:day/:title.html"
      hash['layout'] ||= 'post'
      hash['summary_lines'] ||= 20
      hash['summary_lines'] = hash['summary_lines'].to_i
      hash['latest'] ||= 2
      hash['latest'] = hash['latest'].to_i
      hash['rss_limit'] ||= 20
      hash['rss_limit'] = hash['rss_limit'].to_i
      hash['exclude'] = Array(hash['exclude']).map {|node| Regexp.new(node) }
      hash
    end
    
    class Modeler < BaseModeler
      include Page
      
      DateMatcher = /^(.+\/)*(\d+-\d+-\d+)-(.*)(\.[^.]+)$/
      Matcher = /^(.+\/)*(.*)(\.[^.]+)$/

      def generate
        parsed_page = self.parse_page_file
        data = parsed_page['data']

        filename_data = self.parse_page_filename(@pointer['id'])
        if filename_data.empty?
          #error = "Invalid Filename Format. Format should be: my-post-title.ext"
          #invalid << [@pointer['id'], error] ; next
        end

        data['date'] ||= filename_data['date']

        unless self.formatted_date(data['date'])
          #error = "Invalid Date Format. Date should be: YYYY-MM-DD"
          #invalid << [@pointer['id'], error] ; next
        end

        if data['type'] == 'draft'
          return {"type" => "draft"} if @ruhoh.config['env'] == 'production'
        end  

        data['pointer']       = @pointer
        data['id']            = @pointer['id']
        data['date']          = data['date'].to_s
        data['title']         = data['title'] || filename_data['title']
        data['url']           = self.permalink(data)
        data['layout']        = config['layout'] if data['layout'].nil?
        data['categories']    = Array(data['categories'])
        data['tags']          = Array(data['tags'])
        
        # Register this route for the previewer
        @ruhoh.db.routes[data['url']] = @pointer

        {
          "#{@pointer['id']}" => data
        }
      end

      def formatted_date(date)
        Time.parse(date.to_s).strftime('%Y-%m-%d')
      rescue
        false
      end

      def parse_page_filename(filename)
        data = *filename.match(DateMatcher)
        data = *filename.match(Matcher) if data.empty?
        return {} if data.empty?

        if filename =~ DateMatcher
          {
            "path" => data[1],
            "date" => data[2],
            "slug" => data[3],
            "title" => self.to_title(data[3]),
            "extension" => data[4]
          }
        else
          {
            "path" => data[1],
            "slug" => data[2],
            "title" => self.to_title(data[2]),
            "extension" => data[3]
          }
        end
      end

      # my-post-title ===> My Post Title
      def to_title(file_slug)
        file_slug.gsub(/[^\p{Word}+]/u, ' ').gsub(/\b\w/){$&.upcase}
      end

      # Used in the client implementation to turn a draft into a post.  
      def to_filename(data)
        File.join(@ruhoh.paths.posts, "#{Ruhoh::Utils.to_slug(data['title'])}.#{data['ext']}")
      end

      # Another blatently stolen method from Jekyll
      # The category is only the first one if multiple categories exist.
      def permalink(post)
        date = Date.parse(post['date'])
        title = Ruhoh::Utils.to_url_slug(post['title'])
        format = post['permalink'] || config['permalink']

        if format.include?(':')
          filename = File.basename(post['id'], File.extname(post['id']))
          category = Array(post['categories'])[0]
          category = category.split('/').map {|c| Ruhoh::Utils.to_url_slug(c) }.join('/') if category

          url = {
            "year"       => date.strftime("%Y"),
            "month"      => date.strftime("%m"),
            "day"        => date.strftime("%d"),
            "title"      => title,
            "filename"   => filename,
            "i_day"      => date.strftime("%d").to_i.to_s,
            "i_month"    => date.strftime("%m").to_i.to_s,
            "categories" => category || '',
          }.inject(format) { |result, token|
            result.gsub(/:#{Regexp.escape token.first}/, token.last)
          }.gsub(/\/+/, "/")
        else
          # Use the literal permalink if it is a non-tokenized string.
          url = format.gsub(/^\//, '').split('/').map {|p| CGI::escape(p) }.join('/')
        end  

        @ruhoh.to_url(url)
      end

    end

    
    class Watcher
      def initialize(resource)
        @resource = resource
        @ruhoh = resource.ruhoh
      end
      
      def match(path)
        path =~ %r{^#{@resource.path}}
      end
      
      def update(path)
        path = path.gsub(/^.+\//, '')
        key = @ruhoh.db.routes.key(path)
        @ruhoh.db.routes.delete(key)
        @ruhoh.db.update("type" => type, "id" => path)
      end
    end
    
    class Client
      Help = [
        {
          "command" => "draft <title>",
          "desc" => "Create a new draft. Post title is optional.",
        },
        {
          "command" => "new <title>",
          "desc" => "Create a new post. Post title is optional.",
        },
        {
          "command" => "titleize",
          "desc" => "Update draft filenames to their corresponding titles. Drafts without titles are ignored.",
        },
        {
          "command" => "drafts",
          "desc" => "List all drafts.",
        },
        {
          "command" => "list",
          "desc" => "List all posts.",
        }
      ]

      def initialize(ruhoh, data)
        @ruhoh = ruhoh
        @args = data[:args]
        @options = data[:options]
        @opt_parser = data[:opt_parser]
        @options.ext = (@options.ext || 'md').gsub('.', '')
        @iterator = 0
      end
      
    
      def draft
        self.draft_or_post(:draft)
      end

      def post
        self.draft_or_post(:post)
      end
    
      def draft_or_post(type)
        ruhoh = @ruhoh
        begin
          name = @args[1] || "untitled-#{type}"
          name = "#{name}-#{@iterator}" unless @iterator.zero?
          name = Ruhoh::Utils.to_slug(name)
          filename = File.join(@ruhoh.paths.posts, "#{name}.#{@options.ext}")
          @iterator += 1
        end while File.exist?(filename)
      
        FileUtils.mkdir_p File.dirname(filename)
        output = @ruhoh.db.scaffolds["#{type}.html"].to_s
        output = output.gsub('{{DATE}}', Ruhoh::Resources::Posts.formatted_date(Time.now))
        File.open(filename, 'w:UTF-8') {|f| f.puts output }
      
        Ruhoh::Friend.say { 
          green "New #{type}:" 
          green ruhoh.relative_path(filename)
          green 'View drafts at the URL: /dash'
        }
      end

      # Public: Update draft filenames to their corresponding titles.
      def titleize
        @ruhoh.db.posts['drafts'].each do |file|
          next unless File.basename(file) =~ /^untitled/
          parsed_page = Ruhoh::Utils.parse_page_file(file)
          next unless parsed_page['data']['title']
          new_name = Ruhoh::Utils.to_slug(parsed_page['data']['title'])
          new_file = File.join(File.dirname(file), "#{new_name}#{File.extname(file)}")
          FileUtils.mv(file, new_file)
          Ruhoh::Friend.say { green "Renamed #{file} to: #{new_file}" }
        end
      end
      
      # List pages
      def list
        data = @ruhoh.db.posts

        if @options.verbose
          Ruhoh::Friend.say {
            data.each_value do |p|
              cyan("- #{p['id']}")
              plain("  title: #{p['title']}") 
              plain("  url: #{p['url']}")
            end
          }
        else
          Ruhoh::Friend.say {
            data.each_value do |p|
              cyan("- #{p['id']}")
            end
          }
        end
      end
      
    end
    
    
  end
end