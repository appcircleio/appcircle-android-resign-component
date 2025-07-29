require 'open3'
require 'os'
require 'fileutils'
require 'open-uri'
require 'json'
require 'uri'
require 'dotenv'
Dotenv.load

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def env_has_key(key)
    value = get_env_variable(key)
    return value unless value.nil? || value.empty?
 
    abort("Input #{key} is missing.")
end

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

$signing_file_exts = [".mf", ".rsa", ".dsa", ".ec", ".sf"]
$latest_build_tools = Dir.glob("#{android_home}/build-tools/*").sort.last

def run_command(command, isLogReturn=false)
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
    return run_command("#{$latest_build_tools}/aapt ls #{path} | grep META-INF", true).split("\n")
end

def copy_artifact(current_path, dest_path)
    FileUtils.cp(current_path, dest_path)
end

def is_signed(meta_files) 
    meta_files.each do |file| 
        if file.downcase.include?(".dsa") || file.downcase.include?(".rsa")
            return true
        end
    end
    return false
end

def get_signing_files(meta_files) 
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
    apksigner_options = "--ks \"#{options[:keystore_path]}\" --ks-pass \'pass:#{options[:keystore_password]}\' --ks-key-alias \"#{options[:alias]}\" --key-pass \'pass:#{options[:alias_password]}\'"
    run_command("#{$latest_build_tools}/apksigner sign --in #{path} --out #{path} #{apksigner_options}")
end

def jar_signer(path,options)
    keystore_options = "-keystore \"#{options[:keystore_path]}\" "\
                    "-storepass \'#{options[:keystore_password]}\' "\
                    "-keypass \'#{options[:alias_password]}\'"
    jarsigner_options = "-verbose -sigalg SHA1withRSA -digestalg SHA1"
    run_command("jarsigner #{jarsigner_options} #{keystore_options} #{path} \"#{options[:alias]}\"")
            
end

def get_latest_bundletool_version
    url = "https://api.github.com/repos/google/bundletool/releases/latest"
    response = URI.open(url).read
    data = JSON.parse(response)
    data["tag_name"].gsub(/^v/, '')
end

def run_bundletool(bundle_path, output_path, keystore_options)
    $bundletool_version = get_latest_bundletool_version if $bundletool_version.to_s.strip.downcase == "latest"
  
    bundle_tool_dir = File.join($ac_temp, "bundletool")
    bundle_tool_jar = File.join(bundle_tool_dir, "bundletool.jar")
    bundle_output_dir = File.join($ac_temp, "output", "bundle")
    apks_path = File.join(bundle_output_dir, "app.apks")
  
    FileUtils.mkdir_p(bundle_tool_dir)
    FileUtils.mkdir_p(bundle_output_dir)
  
    unless File.exist?(bundle_tool_jar)
      bundletool_url = "https://github.com/google/bundletool/releases/download/#{$bundletool_version}/bundletool-all-#{$bundletool_version}.jar"
      run_command("curl -L #{bundletool_url} -o #{bundle_tool_jar}")
    end
  
    build_apks_cmd = [
      "java -jar #{bundle_tool_jar}",
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