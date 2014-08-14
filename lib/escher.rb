require 'time'
require 'uri'
require 'digest'

module Escher
  VERSION = '0.0.1'

  def self.default_options
    {:auth_header_name => 'X-Ems-Auth', :date_header_name => 'X-Ems-Date', :vendor_prefix => 'EMS'}
  end

  def self.validate_request(method, url, body, headers, key_db, options = {})

    options = default_options.merge(options)
    auth_header = get_header(options[:auth_header_name], headers)
    date = get_header(options[:date_header_name], headers)

    algo, api_key_id, short_date, credential_scope, signed_headers, signature = parse_auth_header auth_header, options[:vendor_prefix]

    api_secret = key_db[api_key_id]

    signature == generate_signature(algo, api_secret, body, credential_scope, date, headers, method, signed_headers, url, options[:vendor_prefix], options[:auth_header_name], options[:date_header_name])
  end

  def self.get_header(header_name, headers)
    (headers.detect { |header| header[0].downcase == header_name.downcase })[1]
  end

  def self.parse_auth_header(auth_header, vendor_prefix)
    m = /#{vendor_prefix.upcase}-HMAC-(?<algo>[A-Z0-9\,]+) Credential=(?<credentials>[A-Za-z0-9\/\-_]+), SignedHeaders=(?<signed_headers>[A-Za-z\-;]+), Signature=(?<signature>[0-9a-f]+)$/
    .match auth_header
    [
        m['algo'],
    ] + m['credentials'].split('/', 3) + [
        m['signed_headers'].split(';'),
        m['signature'],
    ]
  end

  def self.get_auth_header(client, method, url, body, headers, headers_to_sign, date = Time.now.utc.rfc2822, algo = 'SHA256', options = {})
    options = default_options.merge options
    signature = generate_signature(algo, client[:api_secret], body, client[:credential_scope], date, headers, method, headers_to_sign, url, options[:vendor_prefix], options[:auth_header_name], options[:date_header_name])
    "#{algo_id(options[:vendor_prefix], algo)} Credential=#{client[:api_key_id]}/#{long_date(date)[0..7]}/#{client[:credential_scope]}, SignedHeaders=#{headers_to_sign.uniq.join ';'}, Signature=#{signature}"
  end

  def self.generate_signature(algo, api_secret, body, credential_scope, date, headers, method, signed_headers, url, vendor_prefix, auth_header_name, date_header_name)
    canonicalized_request = canonicalize method, url, body, date, headers, signed_headers, algo, auth_header_name, date_header_name
    string_to_sign = get_string_to_sign credential_scope, canonicalized_request, date, vendor_prefix, algo
    signing_key = calculate_signing_key(api_secret, date, vendor_prefix, credential_scope, algo)
    signature = calculate_signature(algo, signing_key, string_to_sign)
  end

  def self.calculate_signature(algo, signing_key, string_to_sign)
    Digest::HMAC.hexdigest(string_to_sign, signing_key, create_algo(algo))
  end

  def self.canonicalize(method, url, body, date, headers, headers_to_sign, algo, auth_header_name, date_header_name)
    url, query = url.split '?', 2 # URI#parse cannot parse unicode characters in query string TODO use Adressable
    uri = URI.parse(url)

    ([
        method.upcase,
        canonicalize_path(uri),
        canonicalize_query(query),
    ] + canonicalize_headers(date, uri, headers, auth_header_name, date_header_name) + [
        '',
        (headers_to_sign | %w(date host)).join(';'),
        request_body_hash(body, algo)
    ]).join "\n"
  end

  # TODO: extract algo creation
  def self.get_string_to_sign(credential_scope, canonicalized_request, date, prefix, algo)
    date = long_date(date)
    lines = [
        algo_id(prefix, algo),
        date,
        date[0..7] + '/' + credential_scope,
        create_algo(algo).new.hexdigest(canonicalized_request)
    ]
    lines.join "\n"
  end

  def self.create_algo(algo)
    case algo.upcase
      when 'SHA256'
        return Digest::SHA256
      when 'SHA512'
        return Digest::SHA512
      else
        raise('Unidentified hash algorithm')
    end
  end

  def self.long_date(date)
    Time.parse(date).utc.strftime("%Y%m%dT%H%M%SZ")
  end

  def self.algo_id(prefix, algo)
    prefix + '-HMAC-' + algo
  end

  def self.calculate_signing_key(api_secret, date, vendor_prefix, credential_scope, algo)
    signing_key = vendor_prefix + api_secret
    for data in [long_date(date)[0..7]] + credential_scope.split('/') do
      signing_key = Digest::HMAC.digest(data, signing_key, create_algo(algo))
    end
    signing_key
  end

  def self.canonicalize_path(uri)
    path = uri.path
    while path.gsub!(%r{([^/]+)/\.\./?}) { |match| $1 == '..' ? match : '' } do end
    path = path.gsub(%r{/\./}, '/').sub(%r{/\.\z}, '/').gsub(/\/+/, '/')
  end

  def self.canonicalize_headers(date, uri, raw_headers, auth_header_name, date_header_name)
    collect_headers(raw_headers, auth_header_name).merge({date_header_name.downcase => [date], 'host' => [uri.host]}).map { |k, v| k + ':' + (v.sort_by { |x| x }).join(',').gsub(/\s+/, ' ').strip }
  end

  def self.collect_headers(raw_headers, auth_header_name)
    headers = {}
    raw_headers.each { |raw_header|
      if raw_header[0].downcase != auth_header_name.downcase then
        if headers[raw_header[0].downcase] then
          headers[raw_header[0].downcase] << raw_header[1]
        else
          headers[raw_header[0].downcase] = [raw_header[1]]
        end
      end
    }
    headers
  end

  def self.request_body_hash(body, algo)
    create_algo(algo).new.hexdigest body
  end

  def self.canonicalize_query(query)
    query = query || ''
    query.split('&', -1)
    .map { |pair| k, v = pair.split('=', -1)
    if k.include? ' ' then
      [k.str(/\S+/), '']
    else
      [k, v]
    end }
    .map { |pair|
      k, v = pair;
      URI::encode(k.gsub('+', ' ')) + '=' + URI::encode(v || '')
    }
    .sort.join '&'
  end
end
