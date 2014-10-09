fd = open("monsters.txt", "r")
n = nil
num, name, str, agi, hp_min, hp_max, xp = [nil]*7

fd.each_with_index do |ln, i|
  if ln =~ /\#(\d+)\s*:\s*(.*)/
    n = i
    num = $1.to_i
    name = $2
    str, agi, hp_min, hp_max, xp = [nil]*5
  elsif i == n+2 and ln =~ /Strength\s*:\s*(\d+)/
    str = $1.to_i
  elsif i == n+3 and ln =~ /Agility\s*:\s*(\d+)/
    agi = $1.to_i
  elsif i == n+4 and ln =~ /HP\s*:\s*(\d+)(\s*-\s*(\d+))?/
    hp_min = $1.to_i
    hp_max = ($3 or $1).to_i
  elsif i == n+9 and ln =~ /XP\s*:\s*(\d+)/
    xp = $1.to_i
    m = "  { name=\"#{name}\", str=#{str}, agi=#{agi}, hp_min=#{hp_min}, hp_max=#{hp_max}, xp=#{xp} },"
    puts m.ljust(100) + " -- #{num}"
  end
end
