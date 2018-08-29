require 'base64'
require 'cgi'
require 'openssl'
require 'net/http'
require 'net/https'
require 'phony'
require 'pry'

class Zimbra
  def initialize(zimbra_url)
    @zimbra_url = zimbra_url
  end

  def get_token(preauth_key,email)
    timestamp        = (Time.now.to_f * 1000).to_i
    signature        = "#{email}|name|0|#{timestamp}"
    preauth_key_hmac = OpenSSL::HMAC.hexdigest('sha1',preauth_key, signature)

    uri              = URI.parse("#{@zimbra_url}/service/soap")
    http             = Net::HTTP.new(uri.host, uri.port)
    req              = Net::HTTP::Post.new(uri.path)
    http.use_ssl     = true

    payload = {
      "Header" => {},
      "Body" => {
        "AuthRequest" => {
          "_jsns" => "urn:zimbraAccount",
          "account"=> {
              "by"=> "name",
              "_content" => "#{email}"
          },
          "preauth" => {
              "timestamp" => timestamp,
              "expires" => 0,
              "_content" => preauth_key_hmac
          }
        }
      }
    }

    req.body            = payload.to_json
    req["Content-Type"] = "application/json"
    response            = http.request(req)
    if response.is_a?(Net::HTTPSuccess)
      parsed_response     = JSON.parse(response.body)
      begin
        token = parsed_response["Body"]["AuthResponse"]["authToken"][0]["_content"]
        return token
      rescue  => e
        MYLOGGER.error("Error with reponse from zimbra, got 200 with #{response.body}")
        MYLOGGER.error "Error: #{e}"
        MYLOGGER.debug(e.backtrace.inspect)
      end
    end
    false
  end

  def get_calendar_entries(token,email,calendar)
    begin
      url = "#{@zimbra_url}/home/#{email}/#{calendar}?fmt=json&start=%2B4days&end=%2B5days&auth=qp&zauthtoken=#{token}"

      uri              = URI.parse(url)
      http             = Net::HTTP.new(uri.host, uri.port)
      req              = Net::HTTP::Get.new(uri.to_s)
      http.use_ssl     = true

      response         = http.request(req)
      parsed_response  = JSON.parse(response.body)
      return_array     = []
      unless parsed_response.blank?
        parsed_response["appt"].each do |appt|
          appt_name        = appt["inv"][0]["comp"][0]["name"]
          SlackLcx.send_message("Processing #{appt_name}")

          if appt["inv"][0]["comp"][0]["desc"].blank?
            SlackLcx.send_message("Skipping #{appt_name} since desc is blank")
            next
          end

          appt_description = appt["inv"][0]["comp"][0]["desc"][0]["_content"].match(/(.+)\s(\d+)/m)

          if appt_description
            email = appt_description[1].gsub(/\s/,'')
            phone = appt_description[2].gsub(/\s/,'')
            begin
              mail_checker = Mail::Address.new(email)
              email = mail_checker.address
            rescue Mail::Field::ParseError
              email = nil
            end
          else
            # we found no email/phone number combination, try to extract just a phone number
            phone = appt["inv"][0]["comp"][0]["desc"][0]["_content"].gsub(/[^0-9]/,'')
            email = nil
          end

          normalized_phone = Phony.normalize(phone,cc:"43")

          unless Phony.plausible?(Phony.format(normalized_phone))
            appt_data_array = appt["inv"][0]["comp"][0]["desc"][0]["_content"].split("\n")
            appt_data_array.each do |raw_data|
              begin
                normalized_phone = Phony.normalize(raw_data.gsub(/[^0-9]/,''), cc:"43")
              rescue Phony::NormalizationError
                next
              end
              break if Phony.plausible?("+#{normalized_phone}")
            end
            normalized_phone = nil unless Phony.plausible?("+#{normalized_phone}")
          end

          if email.nil?
            appt_data_array = appt["inv"][0]["comp"][0]["desc"][0]["_content"].split("\n")
            appt_data_array.each do |raw_data|
              parsed_data = raw_data.gsub(/\s/,'').match(/.+@.+/)
              if parsed_data
                begin
                  mail_checker = Mail::Address.new(parsed_data[0].gsub(/<.+>/,''))
                  email        = mail_checker.address.downcase
                rescue Mail::Field::ParseError
                  next
                end
                break if email
              end
            end
          end
          next if normalized_phone.nil? && email.nil?

          appt_id          = appt["inv"][0]["id"]
          appt_datetime    = DateTime.parse(appt["inv"][0]["comp"][0]["s"][0]["d"])
          return_hash      = {customer: appt_name, email: email, phone: normalized_phone, id: appt_id, datetime: appt_datetime}
          return_array << return_hash
        end
      end
      return_array
    rescue => e
      SlackLcx.send_message("Error during get_calendar_entries #{e.message}")
      raise
    end
  end

  def get_contacts(token,email,opts={})
    remove_tagged_with  = opts[:remove_tagged_with]
    include_tagged_with = opts[:include_tagged_with]

    url = "#{@zimbra_url}/home/#{email}/contacts?fmt=json&auth=qp&zauthtoken=#{token}"
    uri              = URI.parse(url)
    http             = Net::HTTP.new(uri.host, uri.port)
    req              = Net::HTTP::Get.new(uri.to_s)
    http.use_ssl     = true

    response         = http.request(req)
    parsed_response  = JSON.parse(response.body)
    results = parsed_response["cn"]
    results = results.reject {|contact| contact['tn'].to_s.split(",").exclude?(include_tagged_with)} if include_tagged_with
    results = results.reject {|contact| contact['tn'].to_s.split(",").include?(remove_tagged_with)} if remove_tagged_with
    return_array = []
    results.each do |contact|
      begin
        mobile = "+#{Phony.normalize(contact["_attrs"]["mobilePhone"])}" if contact["_attrs"]["mobilePhone"]
        telephone = "+#{Phony.normalize(contact["_attrs"]["workPhone"])}" if contact["_attrs"]["workPhone"]
      rescue Phony::NormalizationError => e
        puts "Error in phone number for contact #{contact}"
        next
      end
      result_hash = {
        first_name: contact["_attrs"]["firstName"],
        last_name: contact["_attrs"]["lastName"],
        mobile_phone: mobile,
        telephone_number: telephone,
        tags: contact["tn"]
      }
      if contact["_attrs"]["firstName"].nil? && contact["_attrs"]["lastName"].nil? && contact["_attrs"]["company"]
        result_hash[:first_name] = contact["_attrs"]["company"]
        result_hash[:last_name] = "Firma"
      end
      return_array << result_hash
    end
    return_array
  end
end