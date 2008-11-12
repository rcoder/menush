#!/usr/bin/env ruby

# menush.rb 
#
# Use in place of a full-featured shell to allow a user access to only
# a pre-determined set of commands. Designed for limited access to web
# servers, shared systems, or admin/debugging consoles
#
# Menus are defined in a YAML file containing an array of hashes; each
# item in the array will be displayed as an option in the menu, and the
# hash should define the 'prompt' and 'path' keys. The 'defaults' key is 
# optional, and provides a list of command-line arguments to be passed 
# to the command; the 'allow_args' key establishes whether to prompt the
# user for additional arguments before launching the command.
#
# Example menu definition:
# ---
# - prompt: "User admin console"
#   path: /usr/local/sbin/useradm
#   defaults: "--ldap-host=ldap.example.com --default-realm=EXAMPLE.COM"
#   allow_args: false
# - prompt: "Check uptime"
#   path: /usr/bin/uptime
#   allow_args: false

require 'etc'
require 'yaml'
require 'syslog'
require 'rubygems'
require 'highline'

# Path to shared 'default' menu definition file
DEFAULT_MENU_PATH = '/etc/menush/__default__'
# Directory containing per-user config files
USER_MENU_DIR = '/etc/menush'
# Logfile path
LOG_PATH = '/var/log/menush.log'

exit_status = 0

def die(msg, code=1)
  STDERR.puts(msg)
  Syslog.err(msg)
  exit_status = 1
  throw :exit
end

def clear
  puts "\033[2J"
end

# We keep looping until the user asks to exit
catch(:exit) do
  # Set up syslog-based audit log 
  Syslog.open('menush', Syslog::LOG_PID|Syslog::LOG_CONS, Syslog::LOG_AUTHPRIV)

  current_user = Etc.getlogin
  full_config_path = File.join(USER_MENU_DIR, current_user)

  # We use the default config file if none exists for the current user
  menu_path = File.exists?(full_config_path) ? full_config_path : DEFAULT_MENU_PATH

  die('No menu definition found!') unless File.readable?(menu_path)
  Syslog.info("Loading menu shell definition for user #{current_user} from #{menu_path}")

  menu_def = open(menu_path) {|fh| YAML.load(fh) }

  # Verify the menu file format *first*
  menu_def.each do |params|
    path = params['path']
    die('Bad command menu format') if (path.nil? or params['prompt'].nil?)
    die("Invalid command: #{path}") unless File.executable?(path)
  end

  while true
    cli = HighLine.new
    selected = nil

    cli.choose do |menu|
      menu.prompt = "Please make a selection [1-#{menu_def.size + 1}]: "
      menu_def.each_with_index do |params, index|
        prompt = params['prompt']
        menu.choice(prompt) { selected = index }
      end
      menu.choice('Exit')
    end

    die('Exiting.') if selected.nil?

    cmd_params = menu_def[selected]

    # TODO: smart escaping of arguments. For now, we just disallow any input 
    # which contains shell special characters
    cmd_args = ''
    if cmd_params['allow_args']
      safe_char_pat = %r|[-.+=_/,a-zA-Z0-9 ]|
      cmd_args = cli.ask("Command arguments: ") {|q| q.validate = safe_char_pat }
    end

    cmd_string = "#{cmd_params['path']} #{cmd_params['defaults']} #{cmd_args}".strip
    Syslog.info("About to run command for #{current_user}: #{cmd_string.inspect}")

    clear
    status = system(cmd_string)
    if $? != 0
      Syslog.info("Command exited with non-zero status ($?)")
    end
    puts "\n\nPress Return/Enter key to continue..."
    STDIN.gets
    clear
  end # while true
end # catch(:exit)

# If we get here, the user chose to exit, so clean up and shut down
Syslog.close
exit exit_status

