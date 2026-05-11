#!/usr/bin/env ash
# ash-syntax-test.sh — Exhaustive syntax/behavior test for BusyBox ash
# Run on router: ash ash-syntax-test.sh

PASS=0
FAIL=0

ok()   { printf "\033[0;32m[PASS]\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "\033[0;31m[FAIL]\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
info() { printf "\033[0;34m[----]\033[0m %s\n" "$1"; }

# ─── 1. ECHO BEHAVIOR ─────────────────────────────────────────────────────────
info "=== 1. ECHO BEHAVIOR ==="

# 1.1 echo simple
r=$(echo 'hello world')
[ "$r" = "hello world" ] && ok "1.1 echo simple" || fail "1.1 echo simple: $r"

# 1.2 echo con variable en comillas dobles
VAR="test value"
r=$(echo "$VAR")
[ "$r" = "test value" ] && ok "1.2 echo var dobles" || fail "1.2 echo var dobles: $r"

# 1.3 echo con comillas simples (no expande)
r=$(echo '$VAR')
[ "$r" = '$VAR' ] && ok "1.3 echo simples no expande" || fail "1.3 echo simples no expande: $r"

# 1.4 echo -e (puede no funcionar en ash)
r=$(echo -e "a\nb")
lines=$(echo "$r" | wc -l)
[ "$lines" -eq 2 ] && ok "1.4 echo -e newline" || fail "1.4 echo -e newline: lines=$lines"

# 1.5 echo con espacios internos preservados
r=$(echo "meta mark and mask")
[ "$r" = "meta mark and mask" ] && ok "1.5 echo espacios internos" || fail "1.5 echo espacios internos: '$r'"

# ─── 2. VARIABLE EXPANSION ────────────────────────────────────────────────────
info "=== 2. VARIABLE EXPANSION ==="

# 2.1 variable simple
A="hello"
r="${A}"
[ "$r" = "hello" ] && ok "2.1 expansion simple" || fail "2.1: $r"

# 2.2 concatenacion
r="${A} world"
[ "$r" = "hello world" ] && ok "2.2 concat" || fail "2.2: $r"

# 2.3 variable con and literal
MARK="0x00010000"
r="meta mark and ${MARK}"
[ "$r" = "meta mark and 0x00010000" ] && ok "2.3 var con 'and' literal" || fail "2.3: '$r'"

# 2.4 variable con texto pegado despues
r="mark${MARK}end"
[ "$r" = "mark0x00010000end" ] && ok "2.4 texto pegado" || fail "2.4: $r"

# 2.5 default value
UNDEF=""
r="${UNDEF:-default}"
[ "$r" = "default" ] && ok "2.5 default value" || fail "2.5: $r"

# 2.6 nested expansion en echo
r=$(echo "ct mark set meta mark and ${MARK}")
[ "$r" = "ct mark set meta mark and 0x00010000" ] && ok "2.6 nested en echo" || fail "2.6: '$r'"

# ─── 3. QUOTING ───────────────────────────────────────────────────────────────
info "=== 3. QUOTING ==="

# 3.1 single quote preserva todo
r=$(echo 'a $VAR b')
[ "$r" = 'a $VAR b' ] && ok "3.1 single quote preserva" || fail "3.1: $r"

# 3.2 comillas anidadas con '"'"'
r=$(echo '"hello"')
[ "$r" = '"hello"' ] && ok "3.2 comillas anidadas basicas" || fail "3.2: $r"

# 3.3 comilla doble dentro de single via '"'"'
r='he said '"'"'hi'"'"''
[ "$r" = "he said 'hi'" ] && ok "3.3 single dentro de single" || fail "3.3: $r"

# 3.4 variable con comillas dobles en valor
C1='"NSS-Switch comment"'
r=$(echo "$C1")
[ "$r" = '"NSS-Switch comment"' ] && ok "3.4 var con dobles en valor" || fail "3.4: $r"

# 3.5 variable con comillas dobles dentro de echo doble
C1='"NSS-Switch comment"'
r=$(echo "comment '$C1'")
[ "$r" = "comment '\"NSS-Switch comment\"'" ] && ok "3.5 var con dobles en echo doble" || fail "3.5: '$r'"

# 3.6 escribir a archivo con echo y comillas mixtas
TMP=$(mktemp /tmp/ash-test.XXXXXX)
C1='"NSS test"'
echo "nft add rule comment '$C1'" > "$TMP"
r=$(cat "$TMP")
[ "$r" = "nft add rule comment '\"NSS test\"'" ] && ok "3.6 write file comillas mixtas" || fail "3.6: '$r'"
rm -f "$TMP"

# ─── 4. HEREDOC ───────────────────────────────────────────────────────────────
info "=== 4. HEREDOC ==="

# 4.1 heredoc basico
r=$(cat <<EOF
hello
EOF
)
[ "$r" = "hello" ] && ok "4.1 heredoc basico" || fail "4.1: $r"

# 4.2 heredoc con variable expandida
VAR="world"
r=$(cat <<EOF
hello $VAR
EOF
)
[ "$r" = "hello world" ] && ok "4.2 heredoc expande var" || fail "4.2: $r"

# 4.3 heredoc con single quote NO expande
VAR="world"
r=$(cat <<'EOF'
hello $VAR
EOF
)
[ "$r" = 'hello $VAR' ] && ok "4.3 heredoc single no expande" || fail "4.3: $r"

# 4.4 heredoc a archivo
TMP=$(mktemp /tmp/ash-test.XXXXXX)
cat > "$TMP" <<EOF
line one
line two
EOF
lines=$(wc -l < "$TMP")
[ "$lines" -eq 2 ] && ok "4.4 heredoc a archivo" || fail "4.4: lines=$lines"
rm -f "$TMP"

# 4.5 heredoc con backslash escape
r=$(cat <<EOF
meta mark and \${MARK}
EOF
)
[ "$r" = 'meta mark and ${MARK}' ] && ok "4.5 heredoc backslash escape" || fail "4.5: '$r'"

# ─── 5. GREP ──────────────────────────────────────────────────────────────────
info "=== 5. GREP ==="

# 5.1 grep -c exit code con 0 matches
echo "hello" | grep -c "xyz" > /dev/null 2>&1
code=$?
[ "$code" -eq 1 ] && ok "5.1 grep -c 0 matches = exit 1" || fail "5.1: exit=$code"

# 5.2 grep -c con matches
r=$(echo -e "a\nb\na" | grep -c "a")
[ "$r" -eq 2 ] && ok "5.2 grep -c cuenta bien" || fail "5.2: $r"

# 5.3 grep -cv con multiple -e
echo -e "# comment\n\nvalue" | grep -cv -e '^#' -e '^$' > /dev/null 2>&1
code=$?
[ "$code" -eq 1 ] && ok "5.3 grep -cv multi -e 1 match = exit 1" || fail "5.3: exit=$code (BusyBox bug: 0 means ok, 1 means no match)"

# 5.4 grep -oE
r=$(echo "handle 42 other" | grep -oE 'handle [0-9]+' | awk '{print $2}')
[ "$r" = "42" ] && ok "5.4 grep -oE + awk" || fail "5.4: $r"

# 5.5 grep con pipe y variable
CHAIN="nss_bypass_pre"
r=$(echo "jump nss_bypass_pre handle 5" | grep "jump ${CHAIN}" | grep -oE 'handle [0-9]+' | awk '{print $2}')
[ "$r" = "5" ] && ok "5.5 grep pipe chain var" || fail "5.5: $r"

# ─── 6. AWK ───────────────────────────────────────────────────────────────────
info "=== 6. AWK ==="

# 6.1 awk print field
r=$(echo "a b c" | awk '{print $2}')
[ "$r" = "b" ] && ok "6.1 awk field" || fail "6.1: $r"

# 6.2 awk con FS
r=$(echo "a|b|c" | awk -F'|' '{print $2}')
[ "$r" = "b" ] && ok "6.2 awk -F pipe" || fail "6.2: $r"

# 6.3 awk con variable -v
r=$(echo "1|2|3" | awk -F'|' -v n=2 '$1==n {print $2}')
[ "$r" = "2" ] && ok "6.3 awk -v match" || fail "6.3: $r"

# 6.4 awk substr
r=$(echo "hello world" | awk '{print substr($0,1,5)}')
[ "$r" = "hello" ] && ok "6.4 awk substr" || fail "6.4: $r"

# ─── 7. SED ───────────────────────────────────────────────────────────────────
info "=== 7. SED ==="

# 7.1 sed substitution
r=$(echo "hello world" | sed 's/world/earth/')
[ "$r" = "hello earth" ] && ok "7.1 sed s//" || fail "7.1: $r"

# 7.2 sed -i en archivo
TMP=$(mktemp /tmp/ash-test.XXXXXX)
echo "KEY=old" > "$TMP"
sed -i 's/KEY=old/KEY=new/' "$TMP"
r=$(cat "$TMP")
[ "$r" = "KEY=new" ] && ok "7.2 sed -i" || fail "7.2: $r"
rm -f "$TMP"

# 7.3 sed delete lines
TMP=$(mktemp /tmp/ash-test.XXXXXX)
printf "line1\nline2\nline3\n" > "$TMP"
sed -i '2d' "$TMP"
lines=$(wc -l < "$TMP")
[ "$lines" -eq 2 ] && ok "7.3 sed delete line" || fail "7.3: lines=$lines"
rm -f "$TMP"

# ─── 8. READ / STDIN ──────────────────────────────────────────────────────────
info "=== 8. READ / STDIN ==="

# 8.1 read desde pipe (subshell — variable no persiste fuera)
result=""
echo "hello" | while IFS= read -r line; do
    result="$line"
done
# result estara vacio fuera del pipe en ash
[ -z "$result" ] && ok "8.1 pipe while = subshell (var no persiste)" || fail "8.1: result=$result"

# 8.2 read desde archivo (no subshell)
TMP=$(mktemp /tmp/ash-test.XXXXXX)
echo "hello" > "$TMP"
result=""
while IFS= read -r line; do
    result="$line"
done < "$TMP"
[ "$result" = "hello" ] && ok "8.2 while < file persiste" || fail "8.2: result=$result"
rm -f "$TMP"

# 8.3 IFS split
IFS='|' read -r a b c <<EOF
x|y|z
EOF
[ "$a" = "x" ] && [ "$b" = "y" ] && [ "$c" = "z" ] && ok "8.3 IFS split heredoc" || fail "8.3: a=$a b=$b c=$c"

# 8.4 cut como alternativa a IFS read
line="1|tcp|192.168.1.1|any"
a=$(echo "$line" | cut -d'|' -f1)
b=$(echo "$line" | cut -d'|' -f2)
[ "$a" = "1" ] && [ "$b" = "tcp" ] && ok "8.4 cut -d alternativa" || fail "8.4: a=$a b=$b"

# ─── 9. ARITHMETIC ────────────────────────────────────────────────────────────
info "=== 9. ARITHMETIC ==="

# 9.1 $(( )) basico
r=$(( 2 + 3 ))
[ "$r" -eq 5 ] && ok "9.1 aritmetica basica" || fail "9.1: $r"

# 9.2 hex arithmetic
r=$(( 0x00010000 & 0x00010000 ))
[ "$r" -ne 0 ] && ok "9.2 hex AND" || fail "9.2: $r"

# 9.3 printf hex to dec
r=$(printf '%d' 0x00010000)
[ "$r" -eq 65536 ] && ok "9.3 printf hex to dec" || fail "9.3: $r"

# 9.4 mark bit check
MARK=0x00010000
mark_dec=$(printf '%d' "$MARK")
test_mark=65536
r=$(( test_mark & mark_dec ))
[ "$r" -ne 0 ] && ok "9.4 mark bit check" || fail "9.4: r=$r"

# ─── 10. FILE WRITE PATTERNS ──────────────────────────────────────────────────
info "=== 10. FILE WRITE PATTERNS ==="

TMP=$(mktemp /tmp/ash-test.XXXXXX)

# 10.1 echo simple a archivo
echo 'line one' > "$TMP"
r=$(cat "$TMP")
[ "$r" = "line one" ] && ok "10.1 echo > file" || fail "10.1: $r"

# 10.2 echo append
echo 'line two' >> "$TMP"
lines=$(wc -l < "$TMP")
[ "$lines" -eq 2 ] && ok "10.2 echo >> append" || fail "10.2: lines=$lines"

# 10.3 echo con variable expandida a archivo
MARK="0x00010000"
echo "mark=${MARK}" > "$TMP"
r=$(cat "$TMP")
[ "$r" = "mark=0x00010000" ] && ok "10.3 echo var a archivo" || fail "10.3: $r"

# 10.4 echo con espacios internos a archivo
echo "meta mark and ${MARK} != 0" > "$TMP"
r=$(cat "$TMP")
[ "$r" = "meta mark and 0x00010000 != 0" ] && ok "10.4 echo espacios + var a archivo" || fail "10.4: '$r'"

# 10.5 variable con comillas dobles a archivo via echo doble
C1='"NSS comment"'
echo "comment '$C1'" > "$TMP"
r=$(cat "$TMP")
expected="comment '\"NSS comment\"'"
[ "$r" = "$expected" ] && ok "10.5 comillas dobles via var a archivo" || fail "10.5: got='$r' want='$expected'"

# 10.6 nft-style rule completa a archivo
CHAIN="nss_bypass_post"
MARK="0x00010000"
C1='"NSS-Switch: save bypass mark to conntrack"'
echo "    nft add rule inet fw4 ${CHAIN} meta mark and ${MARK} != 0 ct mark set meta mark and ${MARK} comment '${C1}'" > "$TMP"
r=$(cat "$TMP")
echo "$r" | grep -q "meta mark and 0x00010000 != 0 ct mark set meta mark and 0x00010000" && ok "10.6 nft rule completa a archivo" || fail "10.6: '$r'"

rm -f "$TMP"

# ─── 11. FUNCIONES ────────────────────────────────────────────────────────────
info "=== 11. FUNCIONES ==="

# 11.1 funcion basica
my_func() { echo "result"; }
r=$(my_func)
[ "$r" = "result" ] && ok "11.1 funcion basica" || fail "11.1: $r"

# 11.2 funcion con local
my_func2() { local x="local_val"; echo "$x"; }
r=$(my_func2)
[ "$r" = "local_val" ] && ok "11.2 local en funcion" || fail "11.2: $r"

# 11.3 return code
my_func3() { return 1; }
my_func3
[ $? -eq 1 ] && ok "11.3 return code" || fail "11.3: $?"

# 11.4 funcion vacia con true
my_func4() { true; }
my_func4 && ok "11.4 funcion vacia con true" || fail "11.4"

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
printf "\n\033[1m══ RESULTS ══\033[0m\n"
printf "\033[0;32mPASS: %d\033[0m\n" "$PASS"
printf "\033[0;31mFAIL: %d\033[0m\n" "$FAIL"
total=$((PASS+FAIL))
printf "Total: %d\n" "$total"
