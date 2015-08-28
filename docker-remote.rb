require 'json'
require 'uri'
require 'pathname'
require 'net/http'
require 'socket'

def D(object)
  puts object if ENV['DOCKER_DEBUG']
end

class Color
  class << self

    def red(str);        colorize(str, 31) end
    def green(str);      colorize(str, 32) end
    def yellow(str);     colorize(str, 33) end
    def blue(str);       colorize(str, 34) end
    def pink(str);       colorize(str, 35) end
    def light_blue(str); colorize(str, 36) end

    def colorize(str, color_code)
      "\e[#{color_code}m#{str}\e[0m"
    end
  end
end

class Response

  CODE_TO_MSG = {}

  class << self

    def add_code_to_msg(key, value)
      CODE_TO_MSG[key] = value
    end
  end

  def initialize(res, body)
    @res, @body = res, body
  end

  def to_json
    lines = @body.split("\r\n")
    json = lines.size > 1 ?
      lines.map { |line| JSON.parse(line) } : JSON.parse(lines[0])
    D JSON.pretty_generate(json)
    json
  end

  def to_raw
    if @body =~ /\AError/
      STDERR.print @body
      nil
    else
      # stream
      buf = ''
      i = 0
      while i < @body.size
        stream_type = @body[i].unpack(?C)[0]
        len         = @body[i+4,4].unpack(?N)[0]
        payload     = @body[i+8,len]
        if stream_type == 2
          STDERR.print payload
        else
          STDOUT.print payload
        end
        buf << payload
        i += 8 + len
      end
      buf
    end
  end

  def ok?(method)
    msg = CODE_TO_MSG[method][@res.code]
    if success = @res.is_a?(Net::HTTPSuccess)
      STDOUT.puts indent(Color.green(msg))
    else
      STDERR.puts indent(Color.red(msg))
      STDERR.puts indent(@body)
    end
    success
  end

  def indent(string)
    "  #{string}"
  end
end

class QuerySender

  def request(path, params, body, action, header = {})
    path = path.to_s
    socket = UNIXSocket.new('/var/run/docker.sock')
    req = nil
    if action == :get
      uri = build_uri(path, params)
      req = Net::HTTP::Get.new(uri)
    elsif action == :post
      uri = build_uri(path, params)
      req = build_request(uri, body, header)
    elsif action == :delete
      uri = build_uri(path, params)
      req = Net::HTTP::Delete.new(uri)
    end
    write_header(req, socket)
    write_body(req, socket)
    res = read_status_line(socket)
    header = read_header(socket)
    body = read_body(res, header, socket)
    Response.new(res, body)
  end

  def build_request(uri, body, header)
    req = Net::HTTP::Post.new(uri)
    header.each { |k, v| req[k] = v }
    req.content_length = body.bytesize
    req.body = body
    req
  end

  def build_uri(path, params)
    query = build_query(params)
    query.size == 0 ? path : [path, query].join(??)
  end

  def build_query(params)
    params.map do |k,v|
      v = v.is_a?(Hash) ? URI.escape(v.to_json) : v
      [k,'=',v].join
    end.join('&')
  end

  def write_header(req, socket)
    buf = "#{req.method} #{req.path} HTTP/1.1\r\n"
    D Color.light_blue("#{req.method} #{req.path} HTTP/1.1")
    req.each_capitalized do |k,v|
      D Color.pink("#{k}: #{v}")
      buf << "#{k}: #{v}\r\n"
    end
    buf << "\r\n"
    socket.write(buf)
  end

  def write_body(req, socket)
    if req.body
      socket.write(req.body)
    end
  end

  def read_status_line(socket)
    status = socket.readline.chop
    m = /\AHTTP(?:\/(\d+\.\d+))?\s+(\d\d\d)(?:\s+(.*))?\z/in.match(status)
    httpv, code, msg = m.captures
    res = Net::HTTPResponse::CODE_TO_OBJ[code].new(httpv, code, msg)
    if res.is_a?(Net::HTTPSuccess)
      puts Color.green(status)
    elsif res.is_a?(Net::HTTPInformation) || res.is_a?(Net::HTTPRedirection)
      puts Color.yellow(status)
    else
      puts Color.red(status)
    end
    res
  end

  def read_header(socket)
    res = {}
    while (line = socket.readline.chop).size > 0
      D line
      key, value = line.split(/\s*:\s*/, 2)
      res[key] = value
    end
    res
  end

  # Transfer-Encoding: See RFC 2616 section 3.6.1 for definitions
  def read_body(res, header, socket)
    if res.class.body_permitted?
      buf = ''
      if header['Transfer-Encoding'] == 'chunked'
        while (len = socket.readline[/\h+/].hex) > 0
          buf << socket.read(len + 2).to_s[0..-3] # \r\n
        end
      else
        len = header['Content-Length'][/\d+/].to_i
        socket.read(len, buf)
      end
      buf
    end
  end
end

Query = QuerySender.new

class ModelBuilder

  attr_reader :root

  def initialize(root)
    @root = Pathname.new(root)
  end

  def new
    raise 'no subclass'
  end

  def find_and_destroy(name, params)
    if container = find(name)
      container.destroy(params)
    end
  end

  def find(name)
    index(all: true, filters: {name: ["/#{name}$"]})[0]
  end

  Response.add_code_to_msg(:index, {
    '200' => 'no error',
    '400' => 'bad parameter',
    '500' => 'server error'
  })
  def index(params = {})
    res = Query.request(@root + 'json', params, '', :get)
    res.ok?(:index) ? res.to_json.map { |c| new(c['Id']) } : []
  end

  def exec(params, fields, logs_params)
    log = nil
    if container = create(params, fields)
      container.start
      container.wait
      log = container.logs(logs_params)
      container.delete
    end
    log
  end

  def run(params, fields)
    if container = create(params, fields)
      container.start
    end
  end

  Response.add_code_to_msg(:create, {
    '201' => 'no error',
    '404' => 'no such container',
    '406' => 'impossible to attach (container not running)',
    '500' => 'server error'
  })
  def create(params, fields)
    D fields
    res = Query.request(@root + 'create', params, fields.to_json, :post,
                        'Content-Type' => 'application/json')
    res.ok?(:create) ? new(res.to_json['Id']) : nil
  end

  Response.add_code_to_msg(:build, {
    '200' => 'no error',
    '500' => 'server error'
  })
  def build(params, body)
    res = Query.request('/build', params, body, :post)
    if res.ok?(:build)
      res.to_json.each do |stream|
        if stream['stream']
          STDOUT.print stream['stream']
        else
          STDERR.print stream['error']
          STDERR.print stream['errorDetail']
        end
      end
    else
      nil
    end
  end
end

class Model

  def initialize(builder, model_id)
    @root = builder.root
    @model_id = model_id
  end

  Response.add_code_to_msg(:start, {
    '204' => 'no error',
    '304' => 'container already started',
    '404' => 'no such container',
    '500' => 'server error'
  })
  def start
    res = Query.request(@root + @model_id + 'start', {}, '', :post)
    res.ok?(:start)
  end

  Response.add_code_to_msg(:show, {
    '200' => 'no error',
    '404' => 'no such container',
    '500' => 'server error'
  })
  def show
    res = Query.request(@root + @model_id + 'json', {}, '', :get)
    res.ok?(:show) ? res.to_json : nil
  end

  def destroy(params)
    kill(params)
    wait
    delete
  end

  Response.add_code_to_msg(:kill, {
    '204' => 'no error',
    '404' => 'no such container',
    '500' => 'server error'
  })
  def kill(params)
    res = Query.request(@root + @model_id + 'kill', params, '', :post)
    res.ok?(:kill)
  end

  Response.add_code_to_msg(:delete, {
    '204' => 'no error',
    '400' => 'bad parameter',
    '404' => 'no such container',
    '500' => 'server error'
  })
  def delete
    res = Query.request(@root + @model_id, {}, '', :delete)
    res.ok?(:delete)
  end

  Response.add_code_to_msg(:wait, {
    '200' => 'no error',
    '404' => 'no such container',
    '500' => 'server error'
  })
  def wait
    res = Query.request(@root + @model_id + 'wait', {}, '', :post)
    res.ok?(:wait) ? res.to_json : nil
  end

  Response.add_code_to_msg(:logs, {
    '101' => 'no error, hints proxy about hijacking',
    '200' => 'no error, no upgrade header found',
    '404' => 'no such container',
    '500' => 'server error'
  })
  def logs(params)
    res = Query.request(@root + @model_id + 'logs', params, '', :get)
    res.ok?(:logs) ? res.to_raw : nil
  end
end

class ContainerModel < Model
end
class ImageModel < Model
end

class ContainerBuilder < ModelBuilder

  def new(model_id)
    ContainerModel.new(self, model_id)
  end
end
class ImageBuilder < ModelBuilder

  def new(model_id)
    ImageModel.new(self, model_id)
  end
end

Container = ContainerBuilder.new('/containers')
Image = ImageBuilder.new('/images')
