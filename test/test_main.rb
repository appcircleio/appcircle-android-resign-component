# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'stringio'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

FAKE_BUILD_TOOLS = '/fake/android-sdk/build-tools/34.0.0'

KEYSTORE_OPTIONS = {
  keystore_path:     '/tmp/ks/release.jks',
  keystore_password: 'store$pass',
  alias:             'release',
  alias_password:    'alias$pass'
}.freeze

# Every variable main.rb reads. Subprocess runs start with all of them unset so
# the environment of the machine running the tests cannot leak in.
MAIN_ENV_KEYS = %w[
  AC_RESIGN_APK_URL AC_RESIGN_FILENAME AC_RESIGN_TARGETS AC_OUTPUT_DIR
  AC_ANDROID_KEYSTORE_PATH AC_ANDROID_KEYSTORE_PASSWORD AC_ANDROID_ALIAS
  AC_ANDROID_ALIAS_PASSWORD ANDROID_HOME AC_TEMP_DIR AC_ENV_FILE_PATH
  AC_CONVERT_AAB_TO_APK AC_BUNDLETOOL_VERSION AC_BUNDLETOOL_URL
  AC_BUNDLETOOL_BASE_URL AC_BUNDLETOOL_SHA256
].freeze

# Capture everything written to $stdout while the block runs.
def capture_stdout
  captured = StringIO.new
  original = $stdout
  $stdout = captured
  begin
    yield
  ensure
    $stdout = original
  end
  captured.string
end

# Capture everything written to $stderr while the block runs.
def capture_stderr
  captured = StringIO.new
  original = $stderr
  $stderr = captured
  begin
    yield
  ensure
    $stderr = original
  end
  captured.string
end

# Run the block with the given ENV values (nil unsets a key), then restore them.
def with_env(vars)
  saved = vars.keys.to_h { |k| [k, ENV[k]] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

# Run the block, swallow the SystemExit raised by abort and return stderr.
def abort_message
  capture_stderr do
    capture_stdout do
      yield
    rescue SystemExit
      # expected
    end
  end
end

# ─── Subprocess coverage ──────────────────────────────────────────────────────
# Everything under the `if __FILE__ == $PROGRAM_NAME` guard only runs in the
# `ruby main.rb` children spawned by run_main, where in-process Coverage cannot
# see it. Each child is booted with a tiny file (via RUBYOPT) that starts
# Coverage and dumps its result on exit; print_coverage_report merges those
# dumps with the in-process result. main.rb knows nothing about this.
COVERAGE_DIR  = Dir.mktmpdir('android_resign_coverage')
COVERAGE_BOOT = File.join(COVERAGE_DIR, 'coverage_boot.rb')
File.write(COVERAGE_BOOT, <<~BOOT)
  require 'coverage'
  Coverage.start
  at_exit do
    result = Coverage.result
    File.binwrite(File.join(#{COVERAGE_DIR.inspect}, "run-\#{Process.pid}-\#{Time.now.to_f}.dump"), Marshal.dump(result))
  end
BOOT
at_exit { FileUtils.rm_rf(COVERAGE_DIR) }

# Run main.rb in a subprocess with the given ENV hash (nil unsets a key).
# The interpreter is started by absolute path so the PATH tests can unset or
# empty PATH without breaking the spawn itself.
def run_main(env = {}, chdir:)
  clean_env = MAIN_ENV_KEYS.to_h { |k| [k, nil] }
  clean_env['RUBYOPT'] = "-r#{COVERAGE_BOOT} #{ENV['RUBYOPT']}".strip
  Open3.capture3(clean_env.merge(env), RbConfig.ruby, MAIN_RB, chdir: chdir)
end

# Shared stub for the helpers that shell out: record every composed command and
# never run it.
RSpec.shared_context 'stubbed run_command' do
  let(:commands) { [] }

  around do |example|
    saved = $latest_build_tools
    $latest_build_tools = FAKE_BUILD_TOOLS
    example.run
  ensure
    $latest_build_tools = saved
  end

  def stub_run_command(result = '', &block)
    allow(self).to receive(:run_command) do |cmd, *_args|
      commands << cmd
      block ? block.call(cmd) : result
    end
  end
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  it 'returns the value when the key is set' do
    with_env('_AC_TEST_KEY' => 'my_value') do
      expect(get_env_variable('_AC_TEST_KEY')).to eq('my_value')
    end
  end

  it 'returns nil when the key is missing' do
    with_env('_AC_TEST_KEY' => nil) do
      expect(get_env_variable('_AC_TEST_KEY')).to be_nil
    end
  end

  it 'returns nil when the value is an empty string' do
    with_env('_AC_TEST_KEY' => '') do
      expect(get_env_variable('_AC_TEST_KEY')).to be_nil
    end
  end

  it 'keeps surrounding whitespace untouched' do
    with_env('_AC_TEST_KEY' => ' value ') do
      expect(get_env_variable('_AC_TEST_KEY')).to eq(' value ')
    end
  end

  it 'raises TypeError for a nil key' do
    expect { get_env_variable(nil) }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  it 'returns the value when the key is set' do
    with_env('_AC_TEST_KEY' => '/tmp/some/path') do
      expect(env_has_key('_AC_TEST_KEY')).to eq('/tmp/some/path')
    end
  end

  it 'keeps a value containing $ as is' do
    with_env('_AC_TEST_KEY' => 'pa$$word') do
      expect(env_has_key('_AC_TEST_KEY')).to eq('pa$$word')
    end
  end

  it 'aborts with exit status 1 when the key is missing' do
    with_env('_AC_TEST_KEY' => nil) do
      expect { capture_stderr { env_has_key('_AC_TEST_KEY') } }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
    end
  end

  it 'aborts when the value is an empty string' do
    with_env('_AC_TEST_KEY' => '') do
      expect { capture_stderr { env_has_key('_AC_TEST_KEY') } }.to raise_error(SystemExit)
    end
  end

  it 'prints the key name in the abort message' do
    with_env('_AC_TEST_KEY' => nil) do
      expect(abort_message { env_has_key('_AC_TEST_KEY') }).to include('Input _AC_TEST_KEY is missing.')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  context 'positive path' do
    it 'prints the composed command with the @@[command] prefix' do
      out = capture_stdout { run_command('echo hi') }
      expect(out).to include('@@[command] echo hi')
    end

    it 'prints the command output' do
      out = capture_stdout { run_command('echo hello-world') }
      expect(out).to include("hello-world\n")
    end

    it 'returns an empty string when isLogReturn is false' do
      result = nil
      capture_stdout { result = run_command('echo hi') }
      expect(result).to eq('')
    end

    it 'returns every stdout line when isLogReturn is true' do
      result = nil
      capture_stdout { result = run_command("printf 'a\\nb\\n'", true) }
      expect(result).to eq("a\nb\n")
    end
  end

  context 'negative path – command fails' do
    it 'raises RuntimeError with the stderr of the command' do
      expect {
        capture_stdout { run_command("sh -c 'echo boom >&2; exit 3'") }
      }.to raise_error(RuntimeError, /boom/)
    end

    it 'prints the stderr before raising' do
      out = capture_stdout do
        run_command("sh -c 'echo boom >&2; exit 3'")
      rescue RuntimeError
        # expected
      end
      expect(out).to include("boom\n")
    end
  end

  context 'negative path – nil / empty command' do
    it 'raises ArgumentError for nil' do
      expect { run_command(nil) }.to raise_error(ArgumentError, /non-empty command/)
    end

    it 'raises ArgumentError for a blank string' do
      expect { run_command('  ') }.to raise_error(ArgumentError, /non-empty command/)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#update_package' do
  include_context 'stubbed run_command'

  let(:tmpdir)       { Dir.mktmpdir('android_resign_test') }
  let(:targets_json) { File.join(tmpdir, 'targets.json') }
  let(:apk)          { File.join(tmpdir, 'app.apk') }
  let(:mac_changer)  { File.join(PROJECT_ROOT, 'androidmanifest-changer-mac') }

  around do |example|
    saved_path = ENV['PATH']
    example.run
  ensure
    ENV['PATH'] = saved_path
    FileUtils.rm_rf(tmpdir)
  end

  before do
    stub_run_command
    # The 'os' gem is installed on the runners but not required for the tests.
    stub_const('OS', Module.new { def self.mac? = true })
  end

  def write_targets(data)
    File.write(targets_json, JSON.generate(data))
  end

  def update_with_targets(value = targets_json)
    with_env('AC_RESIGN_TARGETS' => value) { capture_stdout { update_package(apk) } }
  end

  context 'positive path' do
    before { write_targets([{ 'Version' => '1.2.3', 'BuildNumber' => '42', 'BundleId' => 'com.example.app' }]) }

    it 'runs the manifest changer with version code, version name and package' do
      update_with_targets
      expect(commands).to eq([
        "chmod +x #{mac_changer}",
        "#{mac_changer}  --versionCode 42 --versionName 1.2.3 --package com.example.app #{apk}"
      ])
    end

    it 'picks the linux changer when the host is not macOS' do
      stub_const('OS', Module.new { def self.mac? = false })
      update_with_targets
      expect(commands.last).to start_with("#{File.join(PROJECT_ROOT, 'androidmanifest-changer-linux')} ")
    end

    it 'appends the latest build-tools directory to PATH' do
      update_with_targets
      expect(ENV['PATH']).to end_with(":#{FAKE_BUILD_TOOLS}/")
    end

    it 'only uses the first target' do
      write_targets([{ 'BundleId' => 'com.first' }, { 'BundleId' => 'com.second' }])
      update_with_targets
      expect(commands.last).to include('--package com.first')
      expect(commands.last).not_to include('com.second')
    end

    it 'leaves out the parameters that are not in the target' do
      write_targets([{ 'Version' => '2.0' }])
      update_with_targets
      expect(commands.last).to eq("#{mac_changer}  --versionName 2.0 #{apk}")
    end
  end

  context 'empty / nil input' do
    it 'skips the manifest change when AC_RESIGN_TARGETS is missing' do
      out = update_with_targets(nil)
      expect(out).to include('Missing $AC_RESIGN_TARGETS. Manifest change skipped')
      expect(commands).to be_empty
    end

    it 'skips the manifest change when AC_RESIGN_TARGETS is empty' do
      out = update_with_targets('')
      expect(out).to include('Missing $AC_RESIGN_TARGETS. Manifest change skipped')
      expect(commands).to be_empty
    end

    it 'skips the manifest change when the target has no version or package' do
      write_targets([{ 'Name' => 'app' }])
      out = update_with_targets
      expect(out).to include('$AC_RESIGN_TARGETS empty. Manifest change skipped')
      expect(commands).to be_empty
    end
  end

  context 'error branch' do
    it 'raises with context when the targets array is empty' do
      write_targets([])
      expect { update_with_targets }
        .to raise_error(RuntimeError, /AC_RESIGN_TARGETS \(#{Regexp.escape(targets_json)}\) must be a JSON array/)
    end

    it 'raises when the targets file does not exist' do
      expect { update_with_targets(File.join(tmpdir, 'missing.json')) }.to raise_error(Errno::ENOENT)
    end

    it 'raises when the targets file is not valid JSON' do
      File.write(targets_json, '{not json')
      expect { update_with_targets }.to raise_error(JSON::ParserError)
    end

    it 'lets a failing manifest changer propagate' do
      write_targets([{ 'BundleId' => 'com.example.app' }])
      stub_run_command { |cmd| cmd.start_with?('chmod') ? '' : raise('changer failed') }
      expect { update_with_targets }.to raise_error(RuntimeError, 'changer failed')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#filter_meta_files' do
  include_context 'stubbed run_command'

  it 'lists the META-INF entries with aapt from the latest build-tools' do
    stub_run_command("META-INF/MANIFEST.MF\nMETA-INF/CERT.RSA\n")
    expect(filter_meta_files('/tmp/app.apk')).to eq(['META-INF/MANIFEST.MF', 'META-INF/CERT.RSA'])
    expect(commands).to eq(["#{FAKE_BUILD_TOOLS}/aapt ls /tmp/app.apk | grep META-INF"])
  end

  it 'asks run_command to return the output' do
    expect(self).to receive(:run_command).with(anything, true).and_return('')
    filter_meta_files('/tmp/app.apk')
  end

  it 'returns an empty list when there is no META-INF entry' do
    stub_run_command('')
    expect(filter_meta_files('/tmp/app.apk')).to eq([])
  end

  it 'raises ArgumentError for a nil path' do
    expect { filter_meta_files(nil) }.to raise_error(ArgumentError, /non-empty artifact path/)
  end

  it 'raises ArgumentError for an empty path' do
    expect { filter_meta_files('') }.to raise_error(ArgumentError, /non-empty artifact path/)
  end

  it 'lets an aapt failure propagate' do
    stub_run_command { raise 'aapt failed' }
    expect { filter_meta_files('/tmp/app.apk') }.to raise_error(RuntimeError, 'aapt failed')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#copy_artifact' do
  let(:tmpdir) { Dir.mktmpdir('android_resign_test') }
  let(:src)    { File.join(tmpdir, 'in.apk') }
  let(:dst)    { File.join(tmpdir, 'out.apk') }

  after { FileUtils.rm_rf(tmpdir) }

  it 'copies the file to the destination and keeps the source' do
    File.write(src, 'apk-bytes')
    copy_artifact(src, dst)
    expect(File.read(dst)).to eq('apk-bytes')
    expect(File.exist?(src)).to be(true)
  end

  it 'overwrites an existing destination' do
    File.write(src, 'new')
    File.write(dst, 'old')
    copy_artifact(src, dst)
    expect(File.read(dst)).to eq('new')
  end

  it 'raises Errno::ENOENT when the source does not exist' do
    expect { copy_artifact(src, dst) }.to raise_error(Errno::ENOENT)
  end

  it 'raises TypeError for a nil source' do
    expect { copy_artifact(nil, dst) }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#is_signed' do
  it 'returns true when an RSA signature file is present' do
    expect(is_signed(['META-INF/MANIFEST.MF', 'META-INF/CERT.RSA'])).to be(true)
  end

  it 'returns true when a DSA signature file is present (case-insensitive)' do
    expect(is_signed(['META-INF/cert.dsa'])).to be(true)
  end

  it 'returns false when only the manifest and .SF files are present' do
    expect(is_signed(['META-INF/MANIFEST.MF', 'META-INF/CERT.SF'])).to be(false)
  end

  it 'returns false for an EC-only signature (only DSA and RSA are checked)' do
    expect(is_signed(['META-INF/CERT.EC'])).to be(false)
  end

  it 'returns false for an empty list' do
    expect(is_signed([])).to be(false)
  end

  it 'raises ArgumentError for nil' do
    expect { is_signed(nil) }.to raise_error(ArgumentError, /META-INF file list is nil/)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_signing_files' do
  it 'returns the signing files, each with a leading space' do
    files = ['META-INF/MANIFEST.MF', 'META-INF/CERT.SF', 'META-INF/CERT.RSA']
    expect(get_signing_files(files)).to eq(' META-INF/MANIFEST.MF META-INF/CERT.SF META-INF/CERT.RSA')
  end

  it 'matches every signing extension case-insensitively' do
    files = %w[META-INF/A.mf META-INF/B.RSA META-INF/C.Dsa META-INF/D.EC META-INF/E.sf]
    expect(get_signing_files(files).split).to eq(files)
  end

  it 'leaves out the other META-INF files' do
    files = ['META-INF/services/foo', 'META-INF/kotlin.kotlin_module', 'META-INF/CERT.RSA']
    expect(get_signing_files(files)).to eq(' META-INF/CERT.RSA')
  end

  it 'returns an empty string for an empty list' do
    expect(get_signing_files([])).to eq('')
  end

  it 'raises ArgumentError for nil' do
    expect { get_signing_files(nil) }.to raise_error(ArgumentError, /META-INF file list is nil/)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#unsign_artifact' do
  include_context 'stubbed run_command'

  it 'removes the signing files with aapt' do
    stub_run_command
    unsign_artifact('/tmp/app.apk', ['META-INF/MANIFEST.MF', 'META-INF/services/foo', 'META-INF/CERT.RSA'])
    expect(commands).to eq(["#{FAKE_BUILD_TOOLS}/aapt remove /tmp/app.apk  META-INF/MANIFEST.MF META-INF/CERT.RSA"])
  end

  it 'still runs aapt remove without files when the list is empty' do
    stub_run_command
    unsign_artifact('/tmp/app.apk', [])
    expect(commands).to eq(["#{FAKE_BUILD_TOOLS}/aapt remove /tmp/app.apk "])
  end

  it 'raises ArgumentError for a nil file list without running aapt' do
    stub_run_command
    expect { unsign_artifact('/tmp/app.apk', nil) }.to raise_error(ArgumentError, /META-INF file list is nil/)
    expect(commands).to be_empty
  end

  it 'lets an aapt failure propagate' do
    stub_run_command { raise 'aapt remove failed' }
    expect { unsign_artifact('/tmp/app.apk', ['META-INF/CERT.RSA']) }.to raise_error(RuntimeError, 'aapt remove failed')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#apk_signer' do
  include_context 'stubbed run_command'

  it 'signs the apk in place with apksigner and single-quotes the passwords' do
    stub_run_command
    apk_signer('/out/app-ac-signed.apk', KEYSTORE_OPTIONS)
    expect(commands).to eq([
      "#{FAKE_BUILD_TOOLS}/apksigner sign --in /out/app-ac-signed.apk --out /out/app-ac-signed.apk " \
      "--ks \"/tmp/ks/release.jks\" --ks-pass 'pass:store$pass' --ks-key-alias \"release\" --key-pass 'pass:alias$pass'"
    ])
  end

  it 'composes empty values when the options are empty' do
    stub_run_command
    apk_signer('/out/app.apk', {})
    expect(commands.first).to end_with("--ks \"\" --ks-pass 'pass:' --ks-key-alias \"\" --key-pass 'pass:'")
  end

  it 'raises ArgumentError for nil options' do
    expect { apk_signer('/out/app.apk', nil) }.to raise_error(ArgumentError, %r{keystore options for "/out/app.apk"})
  end

  it 'lets an apksigner failure propagate' do
    stub_run_command { raise 'apksigner failed' }
    expect { apk_signer('/out/app.apk', KEYSTORE_OPTIONS) }.to raise_error(RuntimeError, 'apksigner failed')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#jar_signer' do
  include_context 'stubbed run_command'

  it 'signs the bundle with jarsigner and single-quotes the passwords' do
    stub_run_command
    jar_signer('/tmp/app.aab', KEYSTORE_OPTIONS)
    expect(commands).to eq([
      'jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 -keystore "/tmp/ks/release.jks" ' \
      "-storepass 'store$pass' -keypass 'alias$pass' /tmp/app.aab \"release\""
    ])
  end

  it 'composes empty values when the options are empty' do
    stub_run_command
    jar_signer('/tmp/app.aab', {})
    expect(commands.first).to end_with("-keystore \"\" -storepass '' -keypass '' /tmp/app.aab \"\"")
  end

  it 'raises ArgumentError for nil options' do
    expect { jar_signer('/tmp/app.aab', nil) }.to raise_error(ArgumentError, /keystore options/)
  end

  it 'lets a jarsigner failure propagate' do
    stub_run_command { raise 'jarsigner failed' }
    expect { jar_signer('/tmp/app.aab', KEYSTORE_OPTIONS) }.to raise_error(RuntimeError, 'jarsigner failed')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_latest_bundletool_version' do
  let(:api_url) { 'https://api.github.com/repos/google/bundletool/releases/latest' }

  def stub_api(body)
    allow(URI).to receive(:open).with(api_url).and_return(StringIO.new(body))
  end

  it 'returns the tag name without the leading v' do
    stub_api('{"tag_name":"v1.17.2"}')
    expect(get_latest_bundletool_version).to eq('1.17.2')
  end

  it 'returns a tag name without a v prefix as is' do
    stub_api('{"tag_name":"1.18.3"}')
    expect(get_latest_bundletool_version).to eq('1.18.3')
  end

  it 'raises with context when tag_name is missing' do
    stub_api('{}')
    expect { get_latest_bundletool_version }.to raise_error(RuntimeError, /tag_name is missing/)
  end

  it 'raises with the API URL when the response is not an object' do
    stub_api('[]')
    expect { get_latest_bundletool_version }.to raise_error(RuntimeError, /#{Regexp.escape(api_url)}/)
  end

  it 'raises JSON::ParserError for a non-JSON response' do
    stub_api('<html>rate limited</html>')
    expect { get_latest_bundletool_version }.to raise_error(JSON::ParserError)
  end

  it 'lets a network error propagate' do
    allow(URI).to receive(:open).and_raise(Errno::ECONNREFUSED)
    expect { get_latest_bundletool_version }.to raise_error(Errno::ECONNREFUSED)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#bundletool_download_url' do
  around do |example|
    saved = $bundletool_version
    with_env('AC_BUNDLETOOL_URL' => nil, 'AC_BUNDLETOOL_BASE_URL' => nil) { example.run }
  ensure
    $bundletool_version = saved
  end

  it 'uses the default version and GitHub when nothing is set' do
    $bundletool_version = nil
    expect(bundletool_download_url).to eq(
      'https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar'
    )
  end

  it 'uses the configured version' do
    $bundletool_version = ' 1.17.0 '
    expect(bundletool_download_url).to end_with('/download/1.17.0/bundletool-all-1.17.0.jar')
  end

  it 'looks up the latest version when the version is latest' do
    $bundletool_version = 'Latest'
    allow(self).to receive(:get_latest_bundletool_version).and_return('9.9.9')
    expect(bundletool_download_url).to end_with('/download/9.9.9/bundletool-all-9.9.9.jar')
  end

  it 'uses AC_BUNDLETOOL_BASE_URL without its trailing slash' do
    $bundletool_version = nil
    with_env('AC_BUNDLETOOL_BASE_URL' => ' https://nexus.example.com/gh/ ') do
      expect(bundletool_download_url).to eq(
        'https://nexus.example.com/gh/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar'
      )
    end
  end

  it 'uses AC_BUNDLETOOL_URL as is and ignores the version' do
    $bundletool_version = 'latest'
    expect(self).not_to receive(:get_latest_bundletool_version)
    with_env('AC_BUNDLETOOL_URL' => 'https://nexus.example.com/bt.jar') do
      out = capture_stdout { expect(bundletool_download_url).to eq('https://nexus.example.com/bt.jar') }
      expect(out).to include('AC_BUNDLETOOL_URL is set')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#mask_url' do
  it 'masks the credentials in a URL' do
    expect(mask_url('https://user:secret@nexus.example.com/bt.jar')).to eq('https://***@nexus.example.com/bt.jar')
  end

  it 'leaves a URL without credentials unchanged' do
    expect(mask_url('https://github.com/google/bundletool')).to eq('https://github.com/google/bundletool')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#verify_bundletool' do
  let(:tmpdir) { Dir.mktmpdir('android_resign_test') }
  let(:jar)    { File.join(tmpdir, 'bundletool.jar.download') }
  let(:url)    { 'https://user:secret@nexus.example.com/bt.jar' }

  around do |example|
    with_env('AC_BUNDLETOOL_SHA256' => nil) { example.run }
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  before { File.binwrite(jar, "PK\x03\x04rest-of-jar".b) }

  it 'accepts a zip file when no checksum is set' do
    expect { verify_bundletool(jar, url) }.not_to raise_error
    expect(File.exist?(jar)).to be(true)
  end

  it 'accepts a matching checksum regardless of case' do
    sha = Digest::SHA256.file(jar).hexdigest.upcase
    with_env('AC_BUNDLETOOL_SHA256' => sha) do
      out = capture_stdout { verify_bundletool(jar, url) }
      expect(out).to include('Bundletool SHA-256 checksum verified.')
    end
  end

  it 'aborts with status 1 and removes the file when it is not a jar' do
    File.write(jar, '<html>login</html>')
    expect { capture_stderr { verify_bundletool(jar, url) } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(File.exist?(jar)).to be(false)
  end

  it 'masks the credentials in the not-a-jar message' do
    File.write(jar, '<html>login</html>')
    msg = abort_message { verify_bundletool(jar, url) }
    expect(msg).to include('is not a valid jar')
    expect(msg).to include('https://***@nexus.example.com/bt.jar')
    expect(msg).not_to include('secret')
  end

  it 'aborts and removes the file on a checksum mismatch' do
    with_env('AC_BUNDLETOOL_SHA256' => 'deadbeef') do
      expect(abort_message { verify_bundletool(jar, url) }).to include('Bundletool SHA-256 mismatch. Expected deadbeef')
    end
    expect(File.exist?(jar)).to be(false)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#download_bundletool' do
  let(:tmpdir) { Dir.mktmpdir('android_resign_test') }
  let(:url)    { 'https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar' }

  around do |example|
    with_env('AC_BUNDLETOOL_SHA256' => nil) { example.run }
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  # Replaces `system("curl", ...)`: writes a jar header to the -o path instead
  # of downloading anything.
  def stub_curl(success: true)
    allow(self).to receive(:system) do |*args|
      File.binwrite(args[args.index('-o') + 1], "PK\x03\x04jar".b) if success
      success
    end
  end

  it 'downloads the jar with curl and returns its path' do
    stub_curl
    path = nil
    capture_stdout { path = download_bundletool(url, tmpdir) }
    expect(path).to eq(File.join(tmpdir, 'bundletool-all-1.18.3.jar'))
    expect(File.exist?(path)).to be(true)
    expect(self).to have_received(:system).with('curl', '-fsSL', '--retry', '3', '-o', "#{path}.download", url)
  end

  it 'reuses an already downloaded jar' do
    stub_curl
    cached = File.join(tmpdir, 'bundletool-all-1.18.3.jar')
    File.write(cached, 'cached')
    out = capture_stdout { expect(download_bundletool(url, tmpdir)).to eq(cached) }
    expect(out).to include('Bundletool is already downloaded')
    expect(self).not_to have_received(:system)
  end

  it 'adds .jar and drops the query string from the cached file name' do
    stub_curl
    path = nil
    capture_stdout { path = download_bundletool('https://nexus.example.com/download/bt?token=abc', tmpdir) }
    expect(path).to eq(File.join(tmpdir, 'bt.jar'))
  end

  it 'aborts and cleans up when curl fails' do
    stub_curl(success: false)
    expect(abort_message { download_bundletool(url, tmpdir) }).to include('Failed to download bundletool')
    expect(Dir.children(tmpdir)).to be_empty
  end

  it 'exits with status 1 when curl fails' do
    stub_curl(success: false)
    expect {
      capture_stdout { capture_stderr { download_bundletool(url, tmpdir) } }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_bundletool' do
  include_context 'stubbed run_command'

  let(:tmpdir)     { Dir.mktmpdir('android_resign_test') }
  let(:output_dir) { File.join(tmpdir, 'output', 'bundle') }
  let(:apks_path)  { File.join(output_dir, 'app.apks') }
  let(:jar)        { '/cache/bundletool-all-1.18.3.jar' }

  around do |example|
    saved = $ac_temp
    $ac_temp = tmpdir
    example.run
  ensure
    $ac_temp = saved
    FileUtils.rm_rf(tmpdir)
  end

  before do
    allow(self).to receive(:bundletool_download_url).and_return('https://example.com/bt.jar')
    allow(self).to receive(:download_bundletool).and_return(jar)
  end

  context 'positive path' do
    before do
      stub_run_command do |cmd|
        FileUtils.touch(File.join(output_dir, 'universal.apk')) if cmd.start_with?('unzip')
        ''
      end
    end

    it 'builds a universal APK set, unzips it and moves the universal apk' do
      run_bundletool('/tmp/app.aab', '/out/app-ac-signed.apk', KEYSTORE_OPTIONS)
      expect(commands).to eq([
        "java -jar \"#{jar}\" build-apks --overwrite --bundle=\"/tmp/app.aab\" --output=\"#{apks_path}\" " \
        '--ks="/tmp/ks/release.jks" --ks-pass=pass:store$pass --ks-key-alias="release" ' \
        '--key-pass=pass:alias$pass --mode=universal',
        "unzip -o #{apks_path} -d #{output_dir}",
        "mv #{File.join(output_dir, 'universal.apk')} /out/app-ac-signed.apk"
      ])
    end

    it 'creates the bundletool and output directories under AC_TEMP_DIR' do
      run_bundletool('/tmp/app.aab', '/out/app-ac-signed.apk', KEYSTORE_OPTIONS)
      expect(File.directory?(File.join(tmpdir, 'bundletool'))).to be(true)
      expect(File.directory?(output_dir)).to be(true)
      expect(self).to have_received(:download_bundletool)
        .with('https://example.com/bt.jar', File.join(tmpdir, 'bundletool'))
    end
  end

  context 'error branch' do
    it 'aborts when the APK set has no universal apk' do
      stub_run_command
      msg = abort_message { run_bundletool('/tmp/app.aab', '/out/app.apk', KEYSTORE_OPTIONS) }
      expect(msg).to include('Universal APK not found inside APK set.')
      expect(commands.grep(/^mv /)).to be_empty
    end

    it 'exits with status 1 when the universal apk is missing' do
      stub_run_command
      expect {
        capture_stderr { run_bundletool('/tmp/app.aab', '/out/app.apk', KEYSTORE_OPTIONS) }
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'lets a bundletool failure propagate' do
      stub_run_command { raise 'build-apks failed' }
      expect { run_bundletool('/tmp/app.aab', '/out/app.apk', KEYSTORE_OPTIONS) }
        .to raise_error(RuntimeError, 'build-apks failed')
    end
  end

  context 'nil input' do
    it 'raises ArgumentError for nil keystore options' do
      expect { run_bundletool('/tmp/app.aab', '/out/app.apk', nil) }.to raise_error(ArgumentError, /keystore options/)
    end

    it 'raises ArgumentError when AC_TEMP_DIR was not read' do
      $ac_temp = nil
      expect { run_bundletool('/tmp/app.aab', '/out/app.apk', KEYSTORE_OPTIONS) }
        .to raise_error(ArgumentError, /AC_TEMP_DIR/)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#beatufy_base_name' do
  it 'replaces -unsigned with -ac-signed' do
    expect(beatufy_base_name('app-release-unsigned')).to eq('app-release-ac-signed')
  end

  it 'does not add -ac-signed twice' do
    expect(beatufy_base_name('app-release-ac-signed')).to eq('app-release-ac-signed')
  end

  it 'appends -ac-signed to a plain name' do
    expect(beatufy_base_name('app-release')).to eq('app-release-ac-signed')
  end

  it 'returns only the suffix for an empty name' do
    expect(beatufy_base_name('')).to eq('-ac-signed')
  end

  it 'raises ArgumentError for nil' do
    expect { beatufy_base_name(nil) }.to raise_error(ArgumentError, /requires a base name/)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#verify_build_artifact' do
  include_context 'stubbed run_command'

  it 'verifies the artifact with jarsigner' do
    stub_run_command("jar verified.\n")
    out = capture_stdout { verify_build_artifact('/out/app.apk') }
    expect(commands).to eq(['jarsigner -verify -verbose -certs /out/app.apk'])
    expect(out).to include('Verified build artifact.')
  end

  it 'aborts with status 1 when the jar is unsigned' do
    stub_run_command("jar is unsigned.\n")
    expect { capture_stderr { verify_build_artifact('/out/app.apk') } }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it 'prints the failure message when the jar is unsigned' do
    stub_run_command("jar is unsigned.\n")
    expect(abort_message { verify_build_artifact('/out/app.apk') }).to include('Failed to verify build artifact.')
  end

  it 'lets a jarsigner failure propagate' do
    stub_run_command { raise 'jarsigner failed' }
    expect { verify_build_artifact('/out/app.apk') }.to raise_error(RuntimeError, 'jarsigner failed')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#zipalign_build_artifact' do
  include_context 'stubbed run_command'

  it 'zipaligns the temp artifact into the output path' do
    stub_run_command
    out = capture_stdout { zipalign_build_artifact('/tmp/app.apk', '/out/app-ac-signed.apk') }
    expect(commands).to eq(["#{FAKE_BUILD_TOOLS}/zipalign -f 4 /tmp/app.apk /out/app-ac-signed.apk"])
    expect(out).to include('Zipalign build artifact...')
  end

  it 'lets a zipalign failure propagate' do
    stub_run_command { raise 'zipalign failed' }
    expect { capture_stdout { zipalign_build_artifact('/tmp/app.apk', '/out/app.apk') } }
      .to raise_error(RuntimeError, 'zipalign failed')
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Subprocess tests: main.rb runs as `ruby main.rb` against stub aapt, zipalign,
# apksigner, jarsigner and curl scripts in a temporary directory. The real
# Android toolchain, the network and the manifest changer are never used
# (AC_RESIGN_TARGETS stays unset, so the changer is skipped).

RSpec.shared_context 'stubbed toolchain' do
  let(:tmpdir)      { Dir.mktmpdir('android_resign_test') }
  let(:work_dir)    { File.join(tmpdir, 'work').tap { |d| FileUtils.mkdir_p(d) } }
  let(:sdk_dir)     { File.join(tmpdir, 'sdk') }
  let(:build_tools) { File.join(sdk_dir, 'build-tools', '34.0.0').tap { |d| FileUtils.mkdir_p(d) } }
  let(:bin_dir)     { File.join(tmpdir, 'bin').tap { |d| FileUtils.mkdir_p(d) } }
  let(:output_dir)  { File.join(tmpdir, 'output').tap { |d| FileUtils.mkdir_p(d) } }
  let(:temp_dir)    { File.join(tmpdir, 'temp').tap { |d| FileUtils.mkdir_p(d) } }
  let(:env_file)    { File.join(tmpdir, 'ac_env').tap { |f| FileUtils.touch(f) } }
  let(:calls_log)   { File.join(tmpdir, 'calls.log') }
  let(:input_name)  { 'app-release-unsigned.apk' }
  let(:meta_files)  { ['META-INF/MANIFEST.MF'] }
  let(:base_env) do
    {
      'PATH'                         => "#{bin_dir}:/usr/bin:/bin",
      'AC_RESIGN_FILENAME'           => input_name,
      'AC_OUTPUT_DIR'                => output_dir,
      'AC_ANDROID_KEYSTORE_PATH'     => '/tmp/ks/release.jks',
      'AC_ANDROID_KEYSTORE_PASSWORD' => 'store$pass',
      'AC_ANDROID_ALIAS'             => 'release',
      'AC_ANDROID_ALIAS_PASSWORD'    => 'alias$pass',
      'ANDROID_HOME'                 => sdk_dir,
      'AC_TEMP_DIR'                  => temp_dir,
      'AC_ENV_FILE_PATH'             => env_file
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  # Writes a /bin/sh stub that logs "<name> <args>" and then runs `body`. Only
  # shell builtins are used, so the stubs also work with an empty PATH.
  def stub_tool(dir, name, body = '')
    path = File.join(dir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      echo "#{name} $*" >> "#{calls_log}"
      #{body}
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def write_input(name = input_name)
    File.write(File.join(work_dir, name), 'artifact-bytes')
  end

  def calls
    File.exist?(calls_log) ? File.read(calls_log).lines.map(&:chomp) : []
  end

  def env_file_lines
    File.read(env_file).lines.map(&:chomp)
  end

  before do
    meta = meta_files.map { |f| "'#{f}'" }.join(' ')
    stub_tool(build_tools, 'aapt', %(if [ "$1" = ls ]; then printf '%s\\n' #{meta}; fi))
    # zipalign -f 4 <in> <out>: copy <in> to <out>.
    stub_tool(build_tools, 'zipalign', %(while IFS= read -r line || [ -n "$line" ]; do echo "$line"; done < "$3" > "$4"))
    # apksigner sign --in <apk> ...: the real tool leaves an .idsig next to the apk.
    stub_tool(build_tools, 'apksigner', %(: > "$3.idsig"))
    stub_tool(bin_dir, 'jarsigner')
    stub_tool(bin_dir, 'curl')
  end
end

RSpec.describe 'ENV validation (subprocess – main.rb)' do
  include_context 'stubbed toolchain'

  let(:signed_apk) { File.join(output_dir, 'app-release-ac-signed.apk') }

  before { write_input }

  shared_examples 'a failing validation' do |key|
    it "exits non-zero with 'Input #{key} is missing.' when it is missing" do
      _out, err, status = run_main(base_env.merge(key => nil), chdir: work_dir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("Input #{key} is missing.")
    end

    it "exits non-zero with 'Input #{key} is missing.' when it is empty" do
      _out, err, status = run_main(base_env.merge(key => ''), chdir: work_dir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("Input #{key} is missing.")
    end
  end

  %w[
    AC_OUTPUT_DIR AC_ANDROID_KEYSTORE_PASSWORD AC_ANDROID_ALIAS AC_ANDROID_ALIAS_PASSWORD
    ANDROID_HOME AC_TEMP_DIR AC_ENV_FILE_PATH
  ].each do |key|
    context key do
      include_examples 'a failing validation', key
    end
  end

  context 'AC_RESIGN_TARGETS' do
    # main.rb treats AC_RESIGN_TARGETS as optional: without it the manifest
    # change is skipped and the artifact is still signed. These tests pin that
    # behavior so existing workflows keep working.
    { 'missing' => nil, 'empty' => '' }.each do |state, value|
      it "skips the manifest change and still signs when it is #{state}" do
        out, err, status = run_main(base_env.merge('AC_RESIGN_TARGETS' => value), chdir: work_dir)
        expect(status.exitstatus).to eq(0), "stderr: #{err}"
        expect(out).to include('Missing $AC_RESIGN_TARGETS. Manifest change skipped')
        expect(File.exist?(signed_apk)).to be(true)
      end
    end
  end

  context 'PATH' do
    # main.rb does not validate PATH itself (adding a check would change the
    # step for existing users); the shell-outs that look a tool up on PATH fail
    # instead. With an empty PATH, `grep` in the aapt pipe is the first one and
    # the step exits non-zero before signing.
    it 'exits non-zero with a command-not-found error when PATH is empty' do
      _out, err, status = run_main(base_env.merge('PATH' => ''), chdir: work_dir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/grep: (No such file or directory|not found)/i)
      expect(File.exist?(signed_apk)).to be(false)
      expect(File.read(env_file)).to be_empty
    end

    # With PATH unset, /bin/sh falls back to its built-in default search path
    # (/usr/bin:/bin), so `curl` (no URL, exits at once) and `grep` resolve to
    # the system ones. The apk flow calls the build-tools by absolute path, so
    # the step still completes. The aab flow is not used here because it would
    # reach the system jarsigner.
    it 'still signs an apk when PATH is missing because build-tools are called by absolute path' do
      _out, err, status = run_main(base_env.merge('PATH' => nil), chdir: work_dir)
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(File.exist?(signed_apk)).to be(true)
      expect(calls.grep(/^(aapt|zipalign|apksigner)/).size).to eq(3)
    end
  end

  context 'AC_ANDROID_KEYSTORE_PATH' do
    { 'missing' => nil, 'empty' => '' }.each do |state, value|
      it "skips the step with exit 0 when it is #{state}" do
        out, _err, status = run_main(base_env.merge('AC_ANDROID_KEYSTORE_PATH' => value), chdir: work_dir)
        expect(status.exitstatus).to eq(0)
        expect(out).to include('AC_ANDROID_KEYSTORE_PATH is not provided. Skipping step.')
        expect(calls.grep(/^(aapt|zipalign|apksigner|jarsigner)/)).to be_empty
      end
    end
  end
end

RSpec.describe 'End-to-end (subprocess – stubbed toolchain)' do
  include_context 'stubbed toolchain'

  let(:signed_apk) { File.join(output_dir, 'app-release-ac-signed.apk') }
  let(:artifact)   { File.join(temp_dir, input_name) }

  context 'unsigned apk' do
    before { write_input }

    it 'exits 0' do
      _out, err, status = run_main(base_env, chdir: work_dir)
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
    end

    it 'downloads the input, lists META-INF, zipaligns and signs with apksigner' do
      run_main(base_env, chdir: work_dir)
      expect(calls).to eq([
        'curl -s -o ./app-release-unsigned.apk -k ',
        "aapt ls #{artifact}",
        "zipalign -f 4 #{artifact} #{signed_apk}",
        "apksigner sign --in #{signed_apk} --out #{signed_apk} --ks /tmp/ks/release.jks " \
        '--ks-pass pass:store$pass --ks-key-alias release --key-pass pass:alias$pass'
      ])
    end

    it 'does not unsign an artifact without DSA or RSA files' do
      out, = run_main(base_env, chdir: work_dir)
      expect(out).to include('No signature file (DSA or RSA) found in META-INF')
      expect(calls.grep(/aapt remove/)).to be_empty
    end

    it 'exports the signed apk path and an empty aab path' do
      run_main(base_env, chdir: work_dir)
      expect(env_file_lines).to eq(["AC_SIGNED_APK_PATH=#{signed_apk}", 'AC_SIGNED_AAB_PATH='])
    end

    it 'deletes the apksigner .idsig file from the output directory' do
      run_main(base_env, chdir: work_dir)
      expect(File.exist?(signed_apk)).to be(true)
      expect(Dir.glob(File.join(output_dir, '*.idsig'))).to be_empty
    end

    it 'prints that conversion is skipped when AC_CONVERT_AAB_TO_APK is true' do
      out, = run_main(base_env.merge('AC_CONVERT_AAB_TO_APK' => 'true'), chdir: work_dir)
      expect(out).to include('AC_CONVERT_AAB_TO_APK is enabled but input is already an APK.')
    end
  end

  context 'signed apk' do
    let(:meta_files) { ['META-INF/MANIFEST.MF', 'META-INF/CERT.SF', 'META-INF/CERT.RSA', 'META-INF/services/x'] }

    before { write_input }

    it 'removes the old signature with aapt before signing' do
      out, err, status = run_main(base_env, chdir: work_dir)
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(out).to include('Signature file (DSA or RSA) found in META-INF, unsigning the build artifact...')
      expect(calls).to include("aapt remove #{artifact} META-INF/MANIFEST.MF META-INF/CERT.SF META-INF/CERT.RSA")
    end
  end

  context 'aab without conversion' do
    let(:input_name) { 'app-release.aab' }
    let(:signed_aab) { File.join(output_dir, 'app-release-ac-signed.aab') }

    before { write_input }

    it 'signs with jarsigner, zipaligns and exports the aab path' do
      _out, err, status = run_main(base_env, chdir: work_dir)
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(calls.drop(2)).to eq([
        'jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 -keystore /tmp/ks/release.jks ' \
        "-storepass store$pass -keypass alias$pass #{artifact} release",
        "zipalign -f 4 #{artifact} #{signed_aab}"
      ])
      expect(env_file_lines).to eq(['AC_SIGNED_APK_PATH=', "AC_SIGNED_AAB_PATH=#{signed_aab}"])
    end
  end

  context 'aab with AC_CONVERT_AAB_TO_APK=true' do
    let(:input_name) { 'app-release.aab' }
    let(:apks_dir)   { File.join(temp_dir, 'output', 'bundle') }
    let(:jar)        { File.join(temp_dir, 'bundletool', 'bundletool-all-1.18.3.jar') }
    let(:env) do
      base_env.merge(
        # run_bundletool does not quote the passwords (unlike apk_signer and
        # jar_signer), so a '$' would be expanded by the shell. Plain
        # passwords keep this test about the conversion flow.
        'AC_ANDROID_KEYSTORE_PASSWORD' => 'storepass',
        'AC_ANDROID_ALIAS_PASSWORD'    => 'aliaspass',
        'AC_CONVERT_AAB_TO_APK' => 'true',
        # Only handed to the curl stub below; nothing is downloaded.
        'AC_BUNDLETOOL_URL'     => 'https://bundletool.invalid/bundletool-all-1.18.3.jar'
      )
    end

    before do
      write_input
      # The bundletool download writes a jar header to the -o path; the
      # input download at the top of main.rb only gets logged.
      stub_tool(bin_dir, 'curl', %(if [ "$1" = -fsSL ]; then printf 'PK\\003\\004' > "$5"; fi))
      stub_tool(bin_dir, 'java')
      # unzip -o <apks> -d <dir>: leave a universal.apk in <dir>.
      stub_tool(bin_dir, 'unzip', %(: > "$4/universal.apk"))
    end

    it 'converts the bundle to a universal apk and exports the apk path' do
      _out, err, status = run_main(env, chdir: work_dir)
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(calls.grep(/^(java|unzip|jarsigner)/)).to eq([
        "java -jar #{jar} build-apks --overwrite --bundle=#{artifact} --output=#{apks_dir}/app.apks " \
        '--ks=/tmp/ks/release.jks --ks-pass=pass:storepass --ks-key-alias=release ' \
        '--key-pass=pass:aliaspass --mode=universal',
        "unzip -o #{apks_dir}/app.apks -d #{apks_dir}"
      ])
      expect(File.exist?(signed_apk)).to be(true)
      expect(env_file_lines).to eq(["AC_SIGNED_APK_PATH=#{signed_apk}", 'AC_SIGNED_AAB_PATH='])
    end
  end

  context 'several artifacts separated by |' do
    let(:input_name) { 'first-unsigned.apk|second.aab' }

    before do
      write_input('first-unsigned.apk')
      write_input('second.aab')
    end

    it 'signs every artifact and exports both paths' do
      _out, err, status = run_main(base_env, chdir: work_dir)
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(env_file_lines).to eq([
        "AC_SIGNED_APK_PATH=#{File.join(output_dir, 'first-ac-signed.apk')}",
        "AC_SIGNED_AAB_PATH=#{File.join(output_dir, 'second-ac-signed.aab')}"
      ])
    end
  end

  context 'apksigner fails' do
    before do
      write_input
      stub_tool(build_tools, 'apksigner', 'echo "keystore was tampered with" >&2; exit 1')
    end

    it 'exits non-zero with the apksigner error and exports nothing' do
      _out, err, status = run_main(base_env, chdir: work_dir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('keystore was tampered with')
      expect(File.read(env_file)).to be_empty
    end
  end

  context 'input file missing' do
    it 'exits non-zero when the downloaded file is not there' do
      _out, err, status = run_main(base_env, chdir: work_dir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('No such file or directory')
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data = result[main_path].dup

  # Merge the per-line hit counts dumped by the `ruby main.rb` subprocesses.
  dumps = Dir.glob(File.join(COVERAGE_DIR, 'run-*.dump'))
  dumps.each do |dump|
    child = Marshal.load(File.binread(dump))
    child_data = child[main_path] || child[child.keys.find { |p| p&.end_with?('main.rb') }]
    next unless child_data
    child_data.each_with_index do |count, i|
      next if count.nil?
      data[i] = (data[i] || 0) + count
    end
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  puts "  \e[90mmerged from this process + #{dumps.size} subprocess run(s)\e[0m" if dumps.any?
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
