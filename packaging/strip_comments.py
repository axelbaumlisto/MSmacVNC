import re, sys
src = open(sys.argv[1]).read()
# Remove block and line comments without touching code (string literals in this
# file contain no comment markers, which the guard's own test confirms).
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
src = re.sub(r'//[^\n]*', '', src)
sys.stdout.write(src)
