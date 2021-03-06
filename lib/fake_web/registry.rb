module FakeWeb

  module RequestMatcher
    ALWAYS_MATCH = Proc.new { |request|  true }
  end

  class Registry #:nodoc:
    include Singleton

    attr_accessor :uri_map, :passthrough_uri_map

    def initialize
      clean_registry
    end

    def clean_registry
      self.uri_map = Hash.new { |hash, key| hash[key] = Hash.new { |i_hash,i_key| i_hash[i_key] = {}} }
    end

    def register_uri(method, uri, request_matcher = ::RequestMatcher::ALWAYS_MATCH,options = {} )
      unless request_matcher.respond_to?(:call)
        # This is a special case, we have to detect in ruby 1.8 whether request_body is a hash, in that case it was not passed
        options = request_matcher
        request_matcher = FakeWeb::RequestMatcher::ALWAYS_MATCH
      end 
      
      uri_map[normalize_uri(uri)][method][request_matcher] = [*[options]].flatten.collect do |option|
        FakeWeb::Responder.new(method, uri, option, option[:times])
      end
    end

    def registered_uri?(method, uri, request_body = FakeWeb::RequestMatcher::ALWAYS_MATCH)
      !responders_for(method, uri, request_body).empty?
    end

    def response_for(method, uri, request_body = FakeWeb::RequestMatcher::ALWAYS_MATCH, &block)

      responders = responders_for(method, uri, request_body)
      return nil if responders.empty?

      next_responder = responders.last
      responders.each do |responder|
        if responder.times and responder.times > 0
          responder.times -= 1
          next_responder = responder
          break
        end
      end

      next_responder.response(&block)
    end

    def register_passthrough_uri(uri)
      self.passthrough_uri_map = {normalize_uri(uri) => {:any => {FakeWeb::RequestMatcher::ALWAYS_MATCH => [true]}}}
    end

    def remove_passthrough_uri
      self.passthrough_uri_map = {}
    end

    def passthrough_uri_matches?(uri)
      uri = normalize_uri(uri)
      uri_map_matches(passthrough_uri_map, :any, uri, "", URI) ||
      uri_map_matches(passthrough_uri_map, :any, uri, "", Regexp)
    end

    private

    def responders_for(method, uri,request_body)
      uri = normalize_uri(uri)
      uri_map_matches(uri_map, method, uri, request_body, URI) ||
      uri_map_matches(uri_map, :any,   uri, request_body, URI) ||
      uri_map_matches(uri_map, method, uri, request_body, Regexp) ||
      uri_map_matches(uri_map, :any,   uri, request_body, Regexp) ||
      []
    end

    def uri_map_matches(map,method, uri, request_body, type_to_check = URI)
      uris_to_check = variations_of_uri_as_strings(uri)
      matches = map.select { |registered_uri, method_hash|
        registered_uri.is_a?(type_to_check) && method_hash.has_key?(method) && method_hash[method].keys.any? { |i|  i.call(request_body) }
      }.select { |registered_uri, method_hash|
        if type_to_check == URI
          uris_to_check.include?(registered_uri.to_s)
        elsif type_to_check == Regexp
          uris_to_check.any? { |u| u.match(registered_uri) }
        end 
      }

      if matches.size > 1
        raise MultipleMatchingURIsError,
          "More than one registered URI matched this request: #{method.to_s.upcase} #{uri}"
      end
      
      matches.map do |_, method_hash| 
        method_hash[method].map do |k,v|
          v if k.call(request_body)
        end.flatten
      end.first

    end


    def variations_of_uri_as_strings(uri_object)
      normalized_uri = normalize_uri(uri_object.dup)
      normalized_uri_string = normalized_uri.to_s

      variations = [normalized_uri_string]

      # if the port is implied in the original, add a copy with an explicit port
      if normalized_uri.default_port == normalized_uri.port
        variations << normalized_uri_string.sub(
                        /#{Regexp.escape(normalized_uri.request_uri)}$/,
                        ":#{normalized_uri.port}#{normalized_uri.request_uri}")
      end

      variations
    end

    def normalize_uri(uri)
      return uri if uri.is_a?(Regexp)
      normalized_uri =
        case uri
        when URI then uri
        when String
          uri = 'http://' + uri unless uri.match('^https?://')
          URI.parse(uri)
        end
      normalized_uri.query = sort_query_params(normalized_uri.query)
      normalized_uri.normalize
    end

    def sort_query_params(query)
      if query.nil? || query.empty?
        nil
      else
        query.split('&').sort.join('&')
      end
    end

  end
end
