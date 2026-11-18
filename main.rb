require 'open3'
# 'os' and 'dotenv' are installed on the runners. The rescue only lets the file
# be required in a bare environment (unit tests); it does not change the step.
begin
  require 'os'
rescue LoadError
end
require 'fileutils'
require 'open-uri'
require 'json'
require 'uri'
require 'digest'
begin
  require 'dotenv'
rescue LoadError
end

$signing_file_exts = [".mf", ".rsa", ".dsa", ".ec", ".sf"]

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def env_has_key(key)
    value = get_env_variable(key)
    return value unless value.nil? || value.empty?
 
    abort("Input #{key} is missing.")
end

def run_command(command, isLogReturn=false)
    raise ArgumentError, "run_command requires a non-empty command string, got #{command.inspect}." if command.nil? || command.to_s.strip.empty?

    puts "@@[command] #{command}"
    status = nil
    stdout_str = nil
    stderr_str = nil
    stdout_all_lines = ""

    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line do |line|
            if isLogReturn
                stdout_all_lines += line
            end
            puts line
        end
        stdout_str = stdout.read
        stderr_str = stderr.read
        status = wait_thr.value
    end

    unless status.success?
        puts stderr_str
        raise stderr_str
    end
    return stdout_all_lines
end

def update_package(apk_path)
    targets_json = get_env_variable('AC_RESIGN_TARGETS')
    if targets_json.nil?
        puts "Missing $AC_RESIGN_TARGETS. Manifest change skipped"
        return
    end
    targets = JSON.parse(File.read(targets_json))
    main_target = targets.first
    unless main_target.is_a?(Hash)
      raise "$AC_RESIGN_TARGETS (#{targets_json}) must be a JSON array whose first item is a target object, got #{main_target.inspect}."
    end
    parameters = ''
    version_name = main_target['Version']
    version_code = main_target['BuildNumber']
    package = main_target['BundleId']
    parameters += " --versionCode #{version_code}" unless version_code.nil?
    parameters += " --versionName #{version_name}" unless version_name.nil?
    parameters += " --package #{package}" unless package.nil?
    if parameters.empty?
      puts '$AC_RESIGN_TARGETS empty. Manifest change skipped'
    else
      parameters += " #{apk_path}"
      ENV['PATH'] = "#{ENV['PATH']}:#{$latest_build_tools}/"
      os = OS.mac? ? 'mac' : 'linux'
      changer_path = "#{File.expand_path(File.dirname(__FILE__))}/androidmanifest-changer-#{os}"
      run_command("chmod +x #{changer_path}")
      cmd = "#{changer_path} #{parameters}"
      run_command(cmd)
    end
end

def filter_meta_files(path)
    raise ArgumentError, "filter_meta_files requires a non-empty artifact path, got #{path.inspect}." if path.nil? || path.to_s.empty?

    return run_command("#{$latest_build_tools}/aapt ls #{path} | grep META-INF", true).split("\n")
end

def copy_artifact(current_path, dest_path)
    FileUtils.cp(current_path, dest_path)
end

def is_signed(meta_files)
    raise ArgumentError, "META-INF file list is nil; cannot determine the signing status." if meta_files.nil?

    meta_files.each do |file|
        if file.downcase.include?(".dsa") || file.downcase.include?(".rsa")
            return true
        end
    end
    return false
end

def get_signing_files(meta_files)
    raise ArgumentError, "META-INF file list is nil; cannot collect the signing files." if meta_files.nil?

    signing_files = ""
    meta_files.each do |file|
        extname = File.extname(file).to_s.downcase
        if $signing_file_exts.include?(extname)
            signing_files += " #{file}"
        end
    end
    return signing_files
end

def unsign_artifact(path, files) 
    signing_files = get_signing_files(files)
    run_command("#{$latest_build_tools}/aapt remove #{path} #{signing_files}")
end

def apk_signer(path,options)
    raise ArgumentError, "apk_signer requires the keystore options for #{path.inspect}, got nil." if options.nil?

    apksigner_options = "--ks \"#{options[:keystore_path]}\" --ks-pass \'pass:#{options[:keystore_password]}\' --ks-key-alias \"#{options[:alias]}\" --key-pass \'pass:#{options[:alias_password]}\'"
    run_command("#{$latest_build_tools}/apksigner sign --in #{path} --out #{path} #{apksigner_options}")
end

def jar_signer(path,options)
    raise ArgumentError, "jar_signer requires the keystore options for #{path.inspect}, got nil." if options.nil?

    keystore_options = "-keystore \"#{options[:keystore_path]}\" "\
                    "-storepass \'#{options[:keystore_password]}\' "\
                    "-keypass \'#{options[:alias_password]}\'"
    jarsigner_options = "-verbose -sigalg SHA1withRSA -digestalg SHA1"
    run_command("jarsigner #{jarsigner_options} #{keystore_options} #{path} \"#{options[:alias]}\"")
            
end

DEFAULT_BUNDLETOOL_VERSION = "1.18.3"
DEFAULT_BUNDLETOOL_BASE_URL = "https://github.com"

def get_latest_bundletool_version
    url = "https://api.github.com/repos/google/bundletool/releases/latest"
    response = URI.open(url).read
    data = JSON.parse(response)
    tag_name = data.is_a?(Hash) ? data["tag_name"] : nil
    raise "Could not read the latest bundletool version from #{url}: tag_name is missing." if tag_name.nil?
    tag_name.gsub(/^v/, '')
end

# Priority: AC_BUNDLETOOL_URL (used as is), then AC_BUNDLETOOL_BASE_URL, then GitHub.
def bundletool_download_url
    full_url = get_env_variable("AC_BUNDLETOOL_URL")&.strip
    unless full_url.to_s.empty?
        puts "AC_BUNDLETOOL_URL is set, AC_BUNDLETOOL_VERSION is not used for the download."
        return full_url
    end

    version = $bundletool_version.to_s.strip
    version = DEFAULT_BUNDLETOOL_VERSION if version.empty?
    version = get_latest_bundletool_version if version.downcase == "latest"
    base_url = get_env_variable("AC_BUNDLETOOL_BASE_URL")&.strip
    base_url = DEFAULT_BUNDLETOOL_BASE_URL if base_url.to_s.empty?
    "#{base_url.chomp('/')}/google/bundletool/releases/download/#{version}/bundletool-all-#{version}.jar"
end

def mask_url(url)
    url.sub(%r{//[^/@]+@}, '//***@')
end

def verify_bundletool(path, url)
    unless File.binread(path, 4) == "PK\x03\x04".b
        FileUtils.rm_f(path)
        abort("@@[error] The file downloaded from #{mask_url(url)} is not a valid jar.")
    end

    expected = get_env_variable("AC_BUNDLETOOL_SHA256")&.strip
    return if expected.to_s.empty?

    actual = Digest::SHA256.file(path).hexdigest
    if actual.casecmp?(expected)
        puts "Bundletool SHA-256 checksum verified."
        return
    end

    FileUtils.rm_f(path)
    abort("@@[error] Bundletool SHA-256 mismatch. Expected #{expected}, got #{actual}.")
end

# The jar is cached by the file name in the URL, so a different version is downloaded again.
def download_bundletool(url, target_dir)
    file_name = File.basename(url.split('?').first)
    file_name = "#{file_name}.jar" unless file_name.end_with?(".jar")
    jar_path = File.join(target_dir, file_name)
    if File.exist?(jar_path)
        puts "Bundletool is already downloaded: #{jar_path}"
        return jar_path
    end

    puts "Downloading bundletool from #{mask_url(url)}"
    tmp_path = "#{jar_path}.download"
    unless system("curl", "-fsSL", "--retry", "3", "-o", tmp_path, url)
        FileUtils.rm_f(tmp_path)
        abort("@@[error] Failed to download bundletool from #{mask_url(url)}. " \
              "Check AC_BUNDLETOOL_VERSION, AC_BUNDLETOOL_URL and AC_BUNDLETOOL_BASE_URL.")
    end
    verify_bundletool(tmp_path, url)
    FileUtils.mv(tmp_path, jar_path)
    jar_path
end

def run_bundletool(bundle_path, output_path, keystore_options)
    raise ArgumentError, "run_bundletool requires the keystore options for #{bundle_path.inspect}, got nil." if keystore_options.nil?
    raise ArgumentError, "run_bundletool requires $ac_temp (AC_TEMP_DIR) to be set." if $ac_temp.nil?

    bundle_tool_dir = File.join($ac_temp, "bundletool")
    bundle_output_dir = File.join($ac_temp, "output", "bundle")
    apks_path = File.join(bundle_output_dir, "app.apks")

    FileUtils.mkdir_p(bundle_tool_dir)
    FileUtils.mkdir_p(bundle_output_dir)

    bundle_tool_jar = download_bundletool(bundletool_download_url, bundle_tool_dir)

    build_apks_cmd = [
      "java -jar \"#{bundle_tool_jar}\"",
      "build-apks",
      "--overwrite",
      "--bundle=\"#{bundle_path}\"",
      "--output=\"#{apks_path}\"",
      "--ks=\"#{keystore_options[:keystore_path]}\"",
      "--ks-pass=pass:#{keystore_options[:keystore_password]}",
      "--ks-key-alias=\"#{keystore_options[:alias]}\"",
      "--key-pass=pass:#{keystore_options[:alias_password]}",
      "--mode=universal"
    ].join(" ")
  
    run_command(build_apks_cmd)
  
    run_command("unzip -o #{apks_path} -d #{bundle_output_dir}")
    universal_apk = File.join(bundle_output_dir, "universal.apk")
    unless File.exist?(universal_apk)
      abort("Universal APK not found inside APK set.")
    end
    run_command("mv #{universal_apk} #{output_path}")
end

def beatufy_base_name(base_name)
    raise ArgumentError, "beatufy_base_name requires a base name, got nil." if base_name.nil?

    "#{base_name.gsub('-unsigned', '').gsub('-ac-signed', '')}-ac-signed"
end

def verify_build_artifact(artifact_path)
    output = run_command("jarsigner -verify -verbose -certs #{artifact_path}")
    if output.include?("jar is unsigned.")
        abort("Failed to verify build artifact.")
    end
    puts "Verified build artifact."
end

def zipalign_build_artifact(artifact_path, output_artifact_path)
    puts "Zipalign build artifact..."
    run_command("#{$latest_build_tools}/zipalign -f 4 #{artifact_path} #{output_artifact_path}")
end

if __FILE__ == $PROGRAM_NAME

Dotenv.load if defined?(Dotenv)

options = {}
options[:keystore_path] = get_env_variable("AC_ANDROID_KEYSTORE_PATH")
apk_url =  get_env_variable("AC_RESIGN_APK_URL")
apk_path = get_env_variable("AC_RESIGN_FILENAME")
ac_output_folder = env_has_key("AC_OUTPUT_DIR")
`curl -s -o "./#{apk_path}" -k "#{apk_url}"`

if options[:keystore_path].nil?
    puts "AC_ANDROID_KEYSTORE_PATH is not provided. Skipping step."
    exit 0
end

options[:keystore_password] = env_has_key("AC_ANDROID_KEYSTORE_PASSWORD")
options[:alias] = env_has_key("AC_ANDROID_ALIAS")
options[:alias_password] = env_has_key("AC_ANDROID_ALIAS_PASSWORD")

android_home = env_has_key("ANDROID_HOME")
$ac_temp = env_has_key("AC_TEMP_DIR")
env_file = env_has_key('AC_ENV_FILE_PATH')
convert_apk = get_env_variable("AC_CONVERT_AAB_TO_APK") == "true"
$bundletool_version = get_env_variable("AC_BUNDLETOOL_VERSION")

$latest_build_tools = Dir.glob("#{android_home}/build-tools/*").sort.last

update_package(apk_path)

apks = (apk_path || "").split("|")
apks.each do |input_artifact_path|
    puts "Signing file: #{input_artifact_path}"
    extname = File.extname(input_artifact_path)
    base_name = File.basename(input_artifact_path, extname)
    artifact_path = "#{$ac_temp}/#{base_name}#{extname}"

    copy_artifact(input_artifact_path, artifact_path)
    meta_files = filter_meta_files(artifact_path)
    if is_signed(meta_files)
        puts "Signature file (DSA or RSA) found in META-INF, unsigning the build artifact..."
        unsign_artifact(artifact_path, meta_files)
    else
        puts "No signature file (DSA or RSA) found in META-INF, no need artifact unsign."
    end

    signed_base_name = beatufy_base_name(base_name)
    output_extname = (extname == ".aab" && convert_apk) ? ".apk" : extname
    output_artifact_path = "#{ac_output_folder}/#{signed_base_name}#{output_extname}"

    if extname == ".apk"
        puts "AC_CONVERT_AAB_TO_APK is enabled but input is already an APK. Skipping conversion step." if convert_apk
        zipalign_build_artifact(artifact_path, output_artifact_path)
        apk_signer(output_artifact_path,options)
    else
        if convert_apk
            run_bundletool(artifact_path, output_artifact_path, options)
        else
            jar_signer(artifact_path,options)
            zipalign_build_artifact(artifact_path, output_artifact_path)
        end
    end
end

signed_apk_path = Dir.glob("#{ac_output_folder}/**/*-ac-signed.apk").join("|")
signed_aab_path = Dir.glob("#{ac_output_folder}/**/*-ac-signed.aab").join("|")

File.delete(*Dir.glob("#{ac_output_folder}/*.idsig"))
puts "Exporting AC_SIGNED_APK_PATH=#{signed_apk_path}"
puts "Exporting AC_SIGNED_AAB_PATH=#{signed_aab_path}"

open(env_file, 'a') { |f|
    f.puts "AC_SIGNED_APK_PATH=#{signed_apk_path}"
    f.puts "AC_SIGNED_AAB_PATH=#{signed_aab_path}"
}

exit 0

end # if __FILE__ == $PROGRAM_NAME
