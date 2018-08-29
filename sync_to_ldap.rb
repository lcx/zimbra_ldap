require 'rubygems'
require 'net/ldap'
require './lib/zimbra'
require 'JSON'
require 'yaml'
config  = YAML.load_file('./config/config.yml')

host    = config["ldap"]["server"]
port    = config["ldap"]["port"]
user    = config["ldap"]["user"]
pass    = config["ldap"]["password"]

config["companies"].each do |company|
  puts "Processing company #{company["name"]}"
  zimbra       = Zimbra.new(company["zimbra_server"])
  zimbra_token = zimbra.get_token(company["zimbra_preauth_token"],company["email"])
  contacts     = zimbra.get_contacts(zimbra_token,company["email"])

  ldap          = Net::LDAP.new
  ldap.host     = host
  ldap.port     = port

  ldap.auth user, pass

  if ldap.bind
    # check if company already exists in ldap
    company_filter = Net::LDAP::Filter.eq("ou", company["name"])
    result = ldap.search(:base => "dc=cloudvox,dc=co",:filter => company_filter)

    # company doesn't exist so let's create it
    if result.empty?
      puts "company is new"
      dn = "ou=#{company["name"]},dc=cloudvox,dc=co"
      attr = {
        :objectclass => ["top", "organizationalUnit"],
      }

      raise unless ldap.add( :dn => dn, :attributes => attr )
    else
      # already exists, so let's clean up
      puts "company exists, cleaning up"
      filter = Net::LDAP::Filter.eq("cn", "*")
      treebase = "ou=#{company["name"]},dc=cloudvox,dc=co"

      ldap.search(:base => treebase, :filter => filter) do |entry|
        if ldap.delete(:dn=>entry.dn)
          puts "delete ok"
        else
          puts "Error Deleting"
          p ldap.get_operation_result
        end
      end
    end

    contacts.each_with_index do |contact,ii|
      dn = "uid=#{ii},ou=#{company["name"]},dc=cloudvox,dc=co"
      next if contact[:mobile_phone].nil? && contact[:telephone_number].nil?
      attr = {
        :cn => "#{contact[:first_name]}, #{contact[:last_name]}",
        :objectclass => ["top", "person", "organizationalPerson", "inetOrgPerson"],
      }

      attr[:givenName]       = contact[:first_name].nil? ? " " : contact[:first_name]
      attr[:sn]              = contact[:last_name].nil? ? " " : contact[:last_name]
      attr[:mobile]          = contact[:mobile_phone] unless contact[:mobile_phone].nil?
      attr[:telephoneNumber] = contact[:telephone_number] unless contact[:telephone_number].nil?

      if ldap.add( :dn => dn, :attributes => attr )
        puts "Added #{contact[:first_name]}, #{contact[:last_name]}. mob: #{contact[:mobile_phone]} tel: #{contact[:telephone_number]}"
      else
        puts "Error adding #{contact[:first_name]}, #{contact[:last_name]}"
        p ldap.get_operation_result
      end
    end

  else
    puts "ooops"
    # authentication failed
    p ldap.get_operation_result
  end
end
