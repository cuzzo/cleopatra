#!/usr/bin/env ruby
# frozen_string_literal: true

# Triage Commits for Cleopatra Training Data Generation
#
# Analyzes all CLEAR forks and produces prioritized commit lists.

require 'json'

MASTER_REF = ENV.fetch('CLEOPATRA_MASTER_REF', 'master')
MASTER_BASE_REF = ENV.fetch('CLEOPATRA_MASTER_BASE_REF', 'origin/master')
MASTER_SINCE = ENV.fetch('CLEOPATRA_MASTER_SINCE', '2026-05-26T22:28:00+0000')
MASTER_LIMIT = ENV.fetch('CLEOPATRA_MASTER_LIMIT', '2000').to_i

REPOS = {
  cheat:   { path: File.expand_path('~/cheat'),   label: 'CLEAR (primary)', priority: 1 },
  clear:   { path: File.expand_path('~/clear'),   label: 'CLEAR (fork)',    priority: 2 },
  easy_vm: { path: File.expand_path('~/easy-vm'), label: 'CLEAR easy-vm',   priority: 3 },
  manual:  { path: File.expand_path('~/manual/clear'), label: 'CLEAR manual', priority: 4 },
  litedb:  { path: File.expand_path('~/litedb'),  label: 'LiteDB',           priority: 5 }
}.freeze

# Paths that indicate generated/transpiled output — avoid
NOISE_PATHS = [
  %r{transpiler\.rb},
  %r{zig_type_mapper\.rb},
  %r{vm_golden_harness},
  %r{transpile-tests},
  %r{\.cht},
  %r{zig/.*\.zig},
  %r{benchmarks/},
  %r{bench_},
  %r{coverage/},
  %r{tmp/},
  %r{site/},
  %r{docs/},
  %r{\.pb\.gz},
  %r{sorbet/},
  %r{stdlib/},
  %r{vendor/},
  %r{\.gitignore},
  %r{\.rubocop},
  %r{claude/i},
  %r{\.devcontainer},
  %r{\.github},
  %r{\.vscode},
].freeze

NOISE_MSG = [
  /^chore\(/, /^style\(/, /^docs?\(/, /^ci\(/,
  /mutant/i, /coverage/i, /sorbet/i, /rubocop/i,
  /byebug/i, /golden/i, /allowlist/i,
  /regenerate/i, /closeout/i,
  /rbi/i, /\.rbi/,
].freeze

# High-value areas for feature requests
FEATURE_AREAS = {
  gems:       { pattern: %r{^gems/},        desc: 'Gems (decomplex/nil-kill/slopcop)', target: 40 },
  minivm:     { pattern: %r{^examples/minivm/}, desc: 'examples/minivm/*.rb',          target: 10 },
  early_vm:   { pattern: nil,                desc: 'Old VM era (old-master branch)',     target: 20 },
  compiler:   { pattern: %r{^src/},          desc: 'Source compiler (after Zig)',        target: 130 },
}.freeze

EARLY_VM_BRANCH = 'old-master'

class CommitTriage
  Result = Struct.new(:repo, :sha, :message, :files, :insertions,
                      :deletions, :category, :scope_tier, :area,
                      :priority_score, :test_files, keyword_init: true)

  def initialize
    @commits = []      # all processed commits
    @seen_sha = Set.new
    @master_recent = []
  end

  def run
    puts '=' * 80
    puts '  Cleopatra Commit Triage'
    puts '  Identifying viable commits for training data generation'
    puts '=' * 80

    # Phase 1: mine commits from each repo
    REPOS.each { |key, repo| mine_repo(key, repo) }

    # Phase 2: deduplicate and score
    deduplicate
    score_and_rank

    # Phase 3: print report
    print_report
    export_json
  end

  private

  def mine_repo(key, repo)
    Dir.chdir(repo[:path]) do
      puts "\n--- #{repo[:label]} ---"

      # --- Simplifications ---
      mine_simp(key)
      mine_typed(key)

      # --- Features ---
      # Target specific areas
      mine_features(key, :gems)
      mine_features(key, :minivm)
      mine_features(key, :early_vm)
      mine_features(key, :compiler)

      # --- Bugs ---
      mine_bugs(key)

      # --- Freshness audit ---
      mine_master_recent(key) if key == :cheat
    end
  end

  def git_log(grep_pattern, extra: '')
    `git log --oneline --all #{extra} --grep='#{grep_pattern}' -i --format='%H@@@%s'`
      .lines.map(&:strip).reject(&:empty?)
  end

  # === SIMPLIFICATIONS ===

  def mine_simp(key)
    lines = git_log('^SIMP')
    lines.each do |line|
      sha, msg = line.split('@@@', 2)
      next unless sha && msg
      next if noisy_msg?(msg)
      info = analyze(key, sha, msg, :simplification)
      next unless info
      @commits << info
    end
    puts "  SIMP: #{lines.size} found"
  end

  def mine_typed(key)
    lines = git_log('^typed:')
    lines.each do |line|
      sha, msg = line.split('@@@', 2)
      next unless sha && msg
      next if noisy_msg?(msg)
      info = analyze(key, sha, msg, :simplification)
      next unless info
      info.priority_score += 15 # typed: are high-value
      @commits << info
    end
    puts "  typed:: #{lines.size}"
  end

  # === FEATURES ===

  def mine_features(key, area)
    cfg = FEATURE_AREAS[area]
    pattern = case area
              when :gems     then 'feat'
              when :minivm   then 'feat'
              when :early_vm then nil  # special
              when :compiler then 'feat'
              end

    if area == :early_vm
      # Early VM: commits from old-master branch touching parser.rb, vm.rb, etc.
      lines = git_log('^feat\\|^add\\|^implement', extra: "--branches=#{EARLY_VM_BRANCH}")
      lines += git_log('^v', extra: "--branches=#{EARLY_VM_BRANCH}")
    else
      lines = git_log(pattern)
    end

    lines.each do |line|
      sha, msg = line.split('@@@', 2)
      next unless sha && msg
      next if noisy_msg?(msg)
      next if msg.match?(/ci:|skip|wip|progress|checkpoint|revert|test\(|spec\(/i)
      next if msg.match?(/closeout|delta|honest.outcome/i)

      info = analyze(key, sha, msg, :feature)
      next unless info

      # Check if commit touches the target area
      touches_area = info.files.any? { |f| cfg[:pattern]&.match?(f) }
      if area == :early_vm
        touches_area = info.files.any? { |f| %w[parser.rb vm.rb compiler.rb lexer.rb types.rb opcodes.rb].include?(File.basename(f)) }
      end

      next unless touches_area

      info.area = area
      @commits << info
    end
  end

  # === BUGS ===

  def mine_bugs(key)
    lines = git_log('^fix')
    count = 0
    lines.each do |line|
      sha, msg = line.split('@@@', 2)
      next unless sha && msg
      next if noisy_msg?(msg)
      next unless msg.match?(/close|fixes?|crash|leak|#\d+|bug|hang|race|corrupt|deadlock/i)
      next if msg.match?(/mutant|coverage|sorbet|rbi|rubocop/i)

      info = analyze(key, sha, msg, :bug)
      next unless info
      @commits << info
      count += 1
    end
    puts "  fixes: #{lines.size} found, #{count} real bugs"
  end

  def mine_master_recent(key)
    range = if system("git rev-parse --verify #{MASTER_BASE_REF} >/dev/null 2>&1")
              "#{MASTER_BASE_REF}..#{MASTER_REF}"
            else
              "#{MASTER_REF} --since='#{MASTER_SINCE}'"
            end
    lines = `git log #{range} --max-count=#{MASTER_LIMIT} --format='%H@@@%s'`
      .lines.map(&:strip).reject(&:empty?)

    lines.each do |line|
      sha, msg = line.split('@@@', 2)
      next unless sha && msg
      @master_recent << analyze_master_commit(key, sha, msg)
    end

    puts "  recent #{MASTER_REF}: #{lines.size} commits from #{range}"
  end

  # === ANALYSIS ===

  def analyze_master_commit(key, sha, msg)
    path = REPOS[key][:path]
    stat = `cd #{path} && git diff-tree --no-commit-id -r --numstat #{sha} 2>/dev/null`.strip
    files = []
    insertions = 0
    deletions = 0

    stat.lines.each do |l|
      cols = l.split("\t")
      next unless cols.size == 3
      files << cols[2].strip
      insertions += cols[0].to_i
      deletions += cols[1].to_i
    end

    total = insertions + deletions
    tier = if total <= 50 && files.size <= 3
             '14B'
           elsif total <= 500 && files.size <= 15
             '30B'
           else
             'large'
           end

    Result.new(repo: key, sha: sha, message: msg,
               files: files, insertions: insertions,
               deletions: deletions, category: :master_recent,
               scope_tier: tier, area: :master, priority_score: 0,
               test_files: files.select { |f| test_file?(f) })
  end

  def analyze(key, sha, msg, category)
    path = REPOS[key][:path]
    stat = `cd #{path} && git diff-tree --no-commit-id -r --numstat #{sha} 2>/dev/null`.strip
    return nil if stat.empty?

    files = []
    insertions = 0
    deletions = 0

    stat.lines.each do |l|
      cols = l.split("\t")
      next unless cols.size == 3
      f = cols[2].strip
      a = cols[0].to_i
      d = cols[1].to_i
      next if a == 0 && d == 0
      files << f
      insertions += a
      deletions += d
    end

    return nil if files.empty?
    return nil if files.any? { |f| NOISE_PATHS.any? { |p| f.match?(p) } }

    total = insertions + deletions

    # Scope tier
    tier = if total <= 50 && files.size <= 3
             '14B'
           elsif total <= 200 && files.size <= 8
             '30B'
           elsif total <= 500 && files.size <= 15
             '30B'  # generous 30B
           else
             'large'
           end

    # Don't store large commits for features
    return nil if category == :feature && tier == 'large'
    return nil if category == :bug && tier == 'large'

    # Don't store if the diff is only test files
    ruby_files = files.select { |f| f.end_with?('.rb') }
    spec_files = files.select { |f| test_file?(f) }
    return nil if category == :feature && spec_files.size == ruby_files.size && ruby_files.any?

    score = 0
    src_files = files.count { |f| f.match?(%r{^src/|^gems/|^lib/|^examples/}) }
    score += src_files * 5
    score += 10 if files.size <= 3 && total <= 50
    score += 8 if msg.match?(/^SIMP/)
    score += 5 if msg.length.between?(20, 120)
    score -= 5 if msg.match?(/\bWIP\b/i)

    Result.new(repo: key, sha: sha, message: msg,
               files: files, insertions: insertions,
               deletions: deletions, category: category,
               scope_tier: tier, area: nil, priority_score: score,
               test_files: spec_files)
  end

  def test_file?(file)
    file.match?(%r{^spec/|^test/|/spec/|/test/|_spec\.rb|_test\.rb})
  end

  def noisy_msg?(msg)
    NOISE_MSG.any? { |p| msg.match?(p) }
  end

  # === DEDUP & RANK ===

  def deduplicate
    # Keep highest-priority repo for each SHA
    @commits.sort_by! { |c| REPOS[c.repo][:priority] }
    uniq = {}
    @commits.each { |c| uniq[c.sha] ||= c }
    @commits = uniq.values
    puts "\nDeduplicated: #{@commits.size} unique commits"
  end

  def score_and_rank
    grouped = @commits.group_by(&:category)
    grouped.each { |_, cc| cc.sort_by! { |c| -c.priority_score } }

    # Ensure diversity: max 30 commits per file per category
    grouped.each do |cat, cc|
      file_counts = Hash.new(0)
      cc.each do |c|
        c.files.each { |f| file_counts[f] += 1 }
      end
      cc.each do |c|
        max_fc = c.files.map { |f| file_counts[f] }.max || 0
        c.priority_score -= [max_fc - 20, 0].max * 2
      end
      cc.sort_by! { |c| -c.priority_score }
    end

    @results = grouped
  end

  # === REPORT ===

  def print_report
    puts "\n#{'=' * 80}"
    puts '  TRIAGE REPORT'
    puts '=' * 80

    print_section('SIMPLIFICATIONS', @results[:simplification] || [], 200)
    print_section('FEATURES', @results[:feature] || [], 200)
    print_section('BUGS', @results[:bug] || [], 100)

    # Stats
    all_tiers = Hash.new(0)
    @commits.each { |c| all_tiers[c.scope_tier] += 1 }

    puts "\n--- Scope Distribution ---"
    all_tiers.sort.each { |k, v| puts "  #{k}: #{v}" }

    puts "\n--- Source Distribution ---"
    REPOS.each do |key, repo|
      cnt = @commits.count { |c| c.repo == key }
      puts "  #{repo[:label]}: #{cnt}"
    end

    puts "\n--- Top Files ---"
    fcount = Hash.new(0)
    @commits.each { |c| c.files.each { |f| fcount[f] += 1 } }
    fcount.sort_by { |_, v| -v }.first(25).each { |f, n| puts "  #{n.to_s.rjust(3)}  #{f}" }

    with_tests = @commits.count { |c| c.test_files && !c.test_files.empty? }
    puts "\n--- Test Association ---"
    puts "  Commits touching tests: #{with_tests}/#{@commits.size}"

    print_master_recent
  end

  def print_master_recent
    puts "\n--- Recent #{MASTER_REF} Commits Not In #{MASTER_BASE_REF} ---"
    if @master_recent.empty?
      puts '  None'
      return
    end

    @master_recent.first(40).each_with_index do |c, i|
      files_s = c.files.first(3).map { |f| File.basename(f) }.join(', ')
      files_s += ', ...' if c.files.size > 3
      puts "  #{i + 1} #{c.sha[0, 9]} | #{c.message[0..90]}"
      puts "       +#{c.insertions}/-#{c.deletions} #{c.files.size}f #{files_s}"
    end
  end

  def print_section(title, commits, target)
    puts "\n--- #{title} (target: #{target}) ---"
    t14 = commits.count { |c| c.scope_tier == '14B' }
    t30 = commits.count { |c| c.scope_tier == '30B' }
    puts "  Total: #{commits.size}  (#{t14} x 14B, #{t30} x 30B, #{commits.size - t14 - t30} large)"

    commits.first(25).each_with_index do |c, i|
      icon = c.scope_tier == '14B' ? "\u2605" : "\u25C7"
      files_s = c.files.first(3).map { |f| File.basename(f) }.join(', ')
      files_s += ', ...' if c.files.size > 3
      area_s = c.area ? "[#{c.area}]" : ''
      puts "  #{i+1} #{icon} #{c.priority_score.to_s.rjust(3)} | #{c.repo.to_s.ljust(7)} #{area_s} | #{c.message[0..85]}"
      puts "       +#{c.insertions}/-#{c.deletions}  #{c.files.size}f  #{files_s}"
    end
  end

  def export_json
    output = {
      metadata: { generated_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z') },
      simplifications: (@results[:simplification] || []).first(200).map { |c| c2h(c) },
      features: (@results[:feature] || []).first(200).map { |c| c2h(c) },
      bugs: (@results[:bug] || []).first(100).map { |c| c2h(c) },
      master_recent: @master_recent.map { |c| c2h(c) },
      stats: {
        simplifications: (@results[:simplification] || []).size,
        features: (@results[:feature] || []).size,
        bugs: (@results[:bug] || []).size,
        master_recent: @master_recent.size,
        tier14: @commits.count { |c| c.scope_tier == '14B' },
        tier30: @commits.count { |c| c.scope_tier == '30B' },
      }
    }

    File.write('triage_results.json', JSON.pretty_generate(output))
    puts "\n  Written: triage_results.json (#{output[:stats].inspect})"
  end

  def c2h(c)
    {
      repo: c.repo, sha: c.sha, message: c.message,
      files: c.files, insertions: c.insertions,
      deletions: c.deletions, scope_tier: c.scope_tier,
      category: c.category, area: c.area,
      test_files: c.test_files || [],
      priority_score: c.priority_score
    }
  end
end

require 'set'
CommitTriage.new.run
