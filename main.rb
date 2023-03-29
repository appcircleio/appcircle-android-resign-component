require 'yaml'
require 'open3'
require 'find'
require 'fileutils'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

options = {}
options[:keystore_path] = get_env_variable("AC_ANDROID_KEYSTORE_PATH")

apk_url = ENV['AC_RESIGN_APK_URL']
apk_path = ENV['AC_RESIGN_FILENAME']
`curl -o "./#{apk_path}" -k #{apk_url}`
# Debug
puts "Debug"
FileUtils.cp(apk_path, "#{ac_output_folder}/ac-test-resigned.apk")
#

if options[:keystore_path].nil?
    puts "AC_ANDROID_KEYSTORE_PATH is not provided. Skipping step."
    exit 0
end

options[:keystore_password] = get_env_variable("AC_ANDROID_KEYSTORE_PASSWORD") || abort('Missing keystore password.')
options[:alias] = get_env_variable("AC_ANDROID_ALIAS") || abort('Missing alias.')
options[:alias_password] = get_env_variable("AC_ANDROID_ALIAS_PASSWORD") || abort('Missing alias password.')

ac_output_folder = get_env_variable("AC_OUTPUT_DIR") || abort('Missing AC_OUTPUT_DIR variable.')
android_home = get_env_variable("ANDROID_HOME") || abort('Missing ANDROID_HOME variable.')
ac_temp = get_env_variable("AC_TEMP_DIR") || abort('Missing AC_TEMP_DIR variable.')




apk_path = get_env_variable("AC_APK_PATH")
#aab_path = get_env_variable("AC_AAB_PATH")

apk_path || abort("Missing apk/aab path.")

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
    apksigner_options = "--ks \"#{options[:keystore_path]}\" --ks-pass \"pass:#{options[:keystore_password]}\" --ks-key-alias \"#{options[:alias]}\" --key-pass \"pass:#{options[:alias_password]}\""
    run_command("#{$latest_build_tools}/apksigner sign --in #{path} --out #{path} --debuggable-apk-permitted true #{apksigner_options}")
end

def jar_signer(path,options)
    keystore_options = "-keystore \"#{options[:keystore_path]}\" "\
                    "-storepass \"#{options[:keystore_password]}\" "\
                    "-keypass \"#{options[:alias_password]}\""
    jarsigner_options = "-verbose -sigalg SHA1withRSA -digestalg SHA1"
    run_command("jarsigner #{jarsigner_options} #{keystore_options} #{path} \"#{options[:alias]}\"")
            
end

def beatufy_base_name(base_name)
    return base_name.gsub("-unsigned", "") + "-ac-signed"
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

apks = (apk_path || "").split("|")
apks.each do |input_artifact_path|
    puts "Signing file: #{input_artifact_path}"
    extname = File.extname(input_artifact_path)
    base_name = File.basename(input_artifact_path, extname)
    artifact_path = "#{ac_temp}/#{base_name}#{extname}"

    copy_artifact(input_artifact_path, artifact_path)
    meta_files = filter_meta_files(artifact_path)
    if is_signed(meta_files)
        puts "Signature file (DSA or RSA) found in META-INF, unsigning the build artifact..."
        unsign_artifact(artifact_path, meta_files)
    else
        puts "No signature file (DSA or RSA) found in META-INF, no need artifact unsign."
    end
    puts "File Extension #{extname}"
    if extname == ".apk" # apksigner
	    signed_base_name = beatufy_base_name(base_name)
        output_artifact_path = "#{ac_output_folder}/#{signed_base_name}#{extname}"
        
	    zipalign_build_artifact(artifact_path, output_artifact_path)
        apk_signer(output_artifact_path,options)
    else #jarsigner
        jar_signer(artifact_path,options)
	    signed_base_name = beatufy_base_name(base_name)
	    output_artifact_path = "#{ac_output_folder}/#{signed_base_name}#{extname}"
	    zipalign_build_artifact(artifact_path, output_artifact_path)
    end
end

signed_apk_path = Dir.glob("#{ac_output_folder}/**/*-ac-signed.apk").join("|")
signed_aab_path = Dir.glob("#{ac_output_folder}/**/*-ac-signed.aab").join("|")

puts "Exporting AC_SIGNED_APK_PATH=#{signed_apk_path}"
puts "Exporting AC_SIGNED_AAB_PATH=#{signed_aab_path}"

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_SIGNED_APK_PATH=#{signed_apk_path}"
    f.puts "AC_SIGNED_AAB_PATH=#{signed_aab_path}"
}

exit 0