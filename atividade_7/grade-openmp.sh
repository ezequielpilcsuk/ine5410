#!/bin/bash
# Usage: grade dir_or_archive [output]

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

echo -e "Grade for $BASE$EXT: $(cat grade)"

cleanup || true

exit 0

__TESTBENCH_MARKER__
� sû[ �:	xպ,^�DpCE8��&�I��ii����.B��L�I3�̤3��tÇ<�M���M�*܋�lV�(R@Q\@��KA*-WA����$�������{��|4s�_���B����:�f� chd$�kiP�������!C#��C�;��Ð(�#�7ܼ@ru Tͷ�����O��տ���7��_����w��_đVJWJ�B��hK�C�6�d�)�2�	���p�+���B���I1j#�dNɎ�Q�������u��� %=mT�:�i6'%�'��QG�|��A*�gV�*+�wI��*	c�ac9D#�AjO#�S��,��(R�����#<=(��-�(r
ae��mH��B�*�) Q;�T,�׽RB9�@;)�-�"�wQ�XY�$i���ź-�^�W������{nAr�D#$���/"�Cz�D� �*(
�H��ŅShة&�|"���2b�h�F#D�£���(uN�+�����6�������������bTf|�� ='���I�&{��+��S��f��J�<�!юؑ�-��9(U4؟�|�`le-$-S~���K���d������ŻBF�\�b9�f�7!�|�(���n@as3q[%�,,#P��4ZT�̣��
RbԚ"���l�`����

R�T��	����ِ�Q�h�H+��F-���^�y9Jps����$�@��0D��xֆ�Z��$L��?8�-$`DLJ9um �@¯��:�*-�M9x�m8�@��B\ApNLq3 ƍ�ώ1���1_2R��TrH�Q�u(V2#n6�d��2�\�$�oq��bP&dP�Ai&���ԴJ���+_{��@(6���`<d���`�8�E��G�A'؜�<�Z1I1��,��BP������T�&[�*���TZ�KU����-\C���)+Xda��� ���啒��y�A�����i� LgF�|X��`+
֪P�_� ��#������A[I����v��F��t�,�GD�������+���;��kp�}1�W���ǳ0AB����{��>��)���� ���"�9���� �0�,��{�)ds��b'�$����"P���v�/�Seg�-4[`T�6)~�+#� HmR�oV}�XW%ѐW�r40OC�  A6�!�B�FY re �T-�p)�!����B�(	�'��FǺ(���Qe:#��o��T�QeK�V��(��κ���H%dH��b��:E&�L~�ڑ"�/�(ܟ�p?��ۑ�p�$s?"���[��%��&Ѽ�j�L���[9Z(���m.5)�v�������G��ZP�`��r~�A*�A�CR@Ç��G����iJ�[�"����ω�H��:Q"*4P���r���T,+!i�$��K�RI^�e��������0k� *�<�F⊿�T�o&�0D ]�8E�Ƽj��#q�����ǉc��3�WP���-R*]xzRnn5���`�i\�y�o�A��	��ʲx�1�W�X���>�1�����������iT}�����?��c(� $��H��Js,W@r;]B�	�L�X�0��� ّ)����G�|������Ls|JF|�h|�;M)�R��h��M1N@��H�9��}�r��c�y��Ea���!@����=8ь��f���A����s4�|
z�"<G@O�O��ArE�P\|r��� G�@"�1��c~�</�13��N��S�F�E�P�_i�	�T�@11�(��C�5�#����+��[�f��F�K�~�"�d��z�����4i=<��"L��Rh��	�7�l��2JdT��a�gs4X{�P�t!^��x�F'���Xr���3>���JsJ�I�T06!����-���]��[�Z�t��{*�	���R%�m
e������*E���r��b��T�<��`�H܋��P�?\��3z:������)c��Ô���MOM&ep��%TnU(|��oٝ�����Me��`�G�^���Bp��-|	�yĺ�I�������R)���3K��<�JJƇVd����!��X�"!>ktAVzNf�\�J��	���u�Za��/�YfWR�@o�h�@d�6g�k* 	Ȫ���TkX ^Vv|f6�K�Z�=u9@z�}���@1<�M ,(T����Ea(�ЖV*���@`����`�&O��T�ӮJd�<�v�������TYV��j�ayF\��������$���,�.T�rS�Y>�O:��Jta5�N��A4�sS�s
,�^�q-���Bƀ�,.n��Ӛ!-����[����n���J�D�8��8(����;l7��I?�؆�xO�ƤN��IO:�w�n����/Ƣ d�.��`�.�+�r!��ė����t���W�a!��0��`�Y�`,�M��i [ 0㘊x�F�z��	Do�(�wc�}����B}��D���Ts�^����`��	�&��䢂H�r�a�6�@Z1 [l�Ф���j�ނj�A�0.�Yc��B'�d]kXYX�Tq� ���bq!�x�ǈ<�qJ�G�w�(;[Ա���**��8����n'����h��b7]�"�E��%�tq6��o�v���А�P��ַ��(*�-+�
Eଡ����ଂH9Y�꠰EJ>d�a��Y�x�1,��ǖ�[�(9w30��gK(���r% l�e�_
����_��Yc~(̝Xa�����q ���t։�b�����Lp���XD��=�?�����DY+Zh���BY��M��%��°����@"�h�>Of��a6Dq
jIHI��"-�{���Lr��b`�#J�����6���Ǖ�8�"D��s�	%�f\ȓ"�d(*��f�����C�w ��uUD: �#1U� �BP�9�/傌g��d���0�Q�{�]���<}XAAj|bzVp�y�`ȧi��q��c%*��ơ%��..;�3�Z¥�Gi�T�ac9'TTr���e.�e���Br6��x���.�S��v���9�/���K���Pz�N�0�K��l�
��s�2�EJ{ ��O���	Q�j����R�� ����A����lsVv�9-q4(/s�9�� ��U�����-��P���).��P�D�,��j��������㮂��
̗���I�U�A~�Ԫ�o�<�*Oy%����O��k��6��t3^z�^y��L�����w��i[�}G~_���X�ޔA,�T\.��yb��e�8���t� �H��zf[+Cd���P1��T�/��N�M3̞M��t&-���jHL��ٻZ�q�.%B�N��@������`�������RY$��$O!��+D��:�M�A�|'#��<�o{�tAK�wb�בb���%
:G���)�&6t�#"����v����С���Op'F.�ί6/_s��s�k��/��]�Ӛ�q�G��_T�_L�k}�e�g�O9�H��sC���;��1>����8aulUCՍ�}KG�sX��巾)�~���ƫ��]�~x���	C��/�1$z����_I+�z�"�����ǞMz�W�k{\+��^:���Ӑ���7߸������7N_tVn��u[�^���{������4a���4�|����.�����?o:Pw��+�?�o<*v��qQ5O��q٦��%�Gm�u��zrڡ#랻u�V��$��J��fu͸�o�X�LȖ�)?]���m��Ǯ�~O���£o_m�{1�Ž��J���\��}�t�$��,w-�2�S�u�;O�}�8��!�o�{}�������|�Y�ˈ9L���Q�����W�<������Ѫ�c;�0޲m͝I��6�O��է�#�s$4�k�Ut��9�X�"�n��o}���]�ʕ�)_v?X=��/��S	c6����F��iK����������m������~8��澚��/�?�V\���,}>���]���bq�.K�>��ؼM����w]�ukP��{�ƣ�ߏ�4����[�w�y���|���R���y��E��%�\�YUR���>Rl�=��̬W�TN/?�*�����~��ڇ���z�����j�Sv/��\�gUω��l\[m��u���.Y]�\`߼UBQ5��w�#_�z�St��Y�e+2���O���t�w�#��̈��S�T�祧z����8�䣍i�/>{p�kM>Q�kO��m^�=���4e���Щ�9o��|���Qݞ���c��2�)r<���Ҋ��/G|_����?�o-w�Ė���V{�6�꺔>�;l]���f����,����3�J\A���Sj��LH���wfr�{���kh�+Űxޏy����o��>=�k9�|~�쯞�v�fǭs�N�N�_���=�mwY©%㖟��[�ys ���pW���W���t[��q������|y�]�����\괸b�u�̜3��{�ԐN��4y�sǉW��3�����?�ɬo����b�rS�٣Kz�$��S�F�߷v߈�_���T:����M�����il^����^�q�FϊQ�n�8����~+�^�s��������?�t�N�sWͽ'�Wަ:�fǼ�k���9n���}���^z�;�{�ˣ=:-�����M;�v~���ĳ�"����.�]�uݥ�G��s^�3?���Oܻ����?�ۿw����_���k����t$f�>�67�]��hύ󎮸d�g��\٢�����3t}��~�{�]ֈY��e��;�ɾ�|eՏy���q�.��댷]Xv�Ӻ�?�eD/��ӉO6wnpO������~�Ȳ�����g:�>8��s��͡/^�S�r]ə�Y3J�~��#����Wu�>W�Yc2���si���v�t̉�Zq�jW�����V1i�Y�n:|��~�=�owo[����O�9��߇L�Kpݜ�[;�R��g��������BW��8�f<��W�_�ڒ{�ְK�n�|����4���tr��o�����7~*-�����4��[M��1�;n�x��tf}�=�t;����OW�bג>_�g�#?�x{+)�q0�\��z>z�����󖾺����a���������c�����=�|~۶m۶m۶m[gl۶m�֙3�}�d��lUr��*�x��꛾����ý��k%�@[�>O��bpi\�qb�WX�qc��<8C����J���YN�\���
��KGC�C�m?e�Ega�xQ��EK�E�{f ��Kn�J2�".�l�w/��4�:$1WEE���E��>74(�x⇴CI�ꠣ�Ъ��
ͼ���43t]	  {992.N`��i��d�'����|��?Ӽg���'����
���Vi��.�㡜AV��FXp�冕E�9 ���r\���՘I�pk��Y�����i(��*�y�2Mxh��l�HD�B����X��/���G�o2��P���m�V'�Wǯ�s ��  �X�������i�h��}�ubn���	�
z95���bd��_̐����%yRI-QL���[��芠O��O
���@[��	�	T���dL̋d[�6vQnqa��)`t|#�._V�e���0��L��x��ݷ��2��#�(ٗ�4�7����3Y��� eM��*G�PA��W���\Н�<=�������{�/��_�D��,���T�&=M�݊a�8���#!8�}��_�����2�����P�qj��R#r�8���с(وMKR��wW�ph��Ct�RST���qh�,�S����#�b���u$�f0��DĐ�T^�Ta���US��k,�v
�Q�#C2�eZ0.뤪�)6����-��xi%Kxt+�2�@S�Mnh�� ��cJTs3i�~�V�6���T��c�=q��p Ml u�R�іJW���k�h�-Q�JG&:�����}��"�i�K�V/:���»]�DP���!��WݘGZ�q�$7� �۟}����@)~�) ��yWOM�Ո.��GR %�߂�z�,(
�OВH���hb=%7�ĊSХ�/K'_�;1ӾCFm�3H�#z�9Za7=�ZD��^�Ǝb*
�9Ym	P�RqhsO5N�0wnŖ��2�I�SX��a~)�7!��t5�?���5���rA�^߀���18A ���"R^�:��ڥ���7J�
�h�څ^�^o$R�#�FƷ��c3/����vXRD����o`��f��D_�5�Z���SQ�Dšd��S�7��d<����1*�>�����q>��f�9G��Tl��E�A�)?j��"�ȹUTE��8�ftm�q�ប@n�)d��b�۹B2�:q�?p-�c\w�h�8�n-Z��Xo����­�Sz��c����v]�T�4h���̭_Ћ�\��خ�7l�l�Vnܮ�+�6�u�]�[�W&M/��mz]�m�ɴݮl정3f]� �3�ضݼ���/�;?bOG�׭��`[^�v=���HH5�k��A7)��7��-�^s����b�O�`rn�k��	W.���薈=j��-7����u���Оb�e��xi�fp^�;ٝ @��KN �r@6`���-Z0�c�`�/��f颧U�5aG�p�ۙ��ET����L�Y�� �(�,�尿?���i��s;��2߸P�f�*�e�h�]�U��.y� ����#17�$@T!�(bA�8+�c}n�c=E�~
�5I|jd����Q�������f2���
ύ�,Wfl]�6R�:��f-	�w�bK/"G�6��b��
�h�8�`-�	���k���K�@��t��&�0ت2����.#��<r9��055��4BU��ĝ|������腊Ly=g���q�ؾ������o������z�=S���?�ԝ����O��l:��6ށ��	������1"�A�GwM����LA�����;[3��K��\�q�%9?�5��e�n�E/���9m��mD;@(�(ф:d�� �<�X6����	�q������uJ��d&$vJA��F#�{#"l���E1�D�D�Ę9�i\�.�3i�)��I�|�
/�ϛ��T� ��R+�ĕ�ؤz¯���1E�/Hi�v���܈��:Cҵ��.M��\�1ޑ��P����F����ppѝ�>.X&�@�߬'����N�k����Ai�\s�@u������P%!R3���;��[_G9�ߌ��[mَ�"�~8&�����3��/E�=��N�s2'�y�:�G�_�G�	K����Vh Y|A��%]�����2�da��U9�G%�q�o~Q@Y����x��_�anW�I��jRa���H�i����H�Y�#��F�xer�1
�����l<��Zi�Ҝ(�w,A=�y��(d�U��D�����z.4��<kN$�a��Ci���;#�}!h&� �5aylt�oNj8F̞�����R�7oM9�4LY^|�aWކB�C�A�h=��d�b"��F5;74��TȠ��_5�V�"����?��k��w���ՕwNQ�u���/�" ���?S�NQ�ڕ��c�>�a��� ��9���D��E�<�	3xvڅ����Y~�u���b���&*���`I�<x�*n�
跽Ow ���rd�-�ÇG/�.��˝�洏�s=�23j�2W�z�F@s���T��栝�gf���!{'Rq=��/�]�Z�+u�J�4����J[.ߋ��a�m�;LN"��=���*`:���'���Q-�d��sl����x�yv��+�ޣ�pX+w�����g�n��LD�3nu�׃�p�q �{!��X�e�<z׫�х@0��RC����m{3��O�T<����^f4g��DG��L�,��Xˆ\���P�oy6��K���6T�� ��h4Vd��q@�&�%�A�Uk�����t6+:�E@�4���< ��i�y�%�1��R��+�BKl4H��X�����n�1�@;�1�~в�)�p[jC�X+�L��Q,���~Ce[��*N� �'w�<օ�J�S.����*'�՚�FGh1+��U��g�L(25�b�����D��FK���Ubz���q,�C��,~<+8���g��D���5��#�N����>���V�674��C��Ud���qz�ߌ�_^|��r�~�����]��gJ��A���^�}�>�@J�@zmߔO8#t ]JA�w�uG�?������5@�#B��	G[��o���Ϩ��5����m���8>6ϔ�FA�(�[ EH|�u�4 �"���L�u��<>Lv	��H�~�t��v���=���#2L+O#1��O�Y�#��Ծ���W���x��.�a����ZW��(���b�D����Uk�z�����\�h���l�H��q�pm�K>"A�ˇ�uܝ�[gO��O�h��i�?tqoz������c�u�}����p��v����Ο��}��q{�6�	e}���@xA�	a_O��FA-c6MJ#a��7ך�5Ю����XR���ˀG�<9pr^.�?�R����u��;��A��q��g& �%��J%i��5 @gA%� Ke�Dv����À�� �7�pE���B���b'*��/�%�4&���b�ͅ�L�G@ȕN �"���n�ۍGm�����k�������SF[o�C���"��z��(��#�	����$�|��a��U�>��Y�и��Ə������b�Iք%�	K�2�Е�p����kXܭ`{�T�;���'<�U����h똖(`�`Ϋ�a��V�Q@�ͱ�Jo��E��B���f�戲��SH%5��4�5�`⇃�7

I���!�:D{�_F��CܸM�t�I#�e+u����5���(�g��ғ^���%f���7�q�ڰ��ǯ6D��L�۲i�L��S�oU"�v,�������`�������:Z��:h͢�S��o� �1�dgb��)I��5����L��й^���A��V��S�]����΢� l}�ȴ�PTj}۝ ��+cz�@2Z飧���Z��ߔ`*7֞�#��jr��τr�_�^��	�w/S��V�B�M�w����%˪�ƪ17M�}�"���� �<���aៀS_�f�ǲ���PH<�uL| �0�$��H�����*�-�{5Ϭ`!� 	q�D��Ę�-oZ�Ā�����鋞�H1s�[��49�rD���7utr$��(�ylҔ�IeD��K��,~�fW�D`@�>P�5t�Aઉ�4 
����Љ!O�~ckLβ�O�7}��HӞ�$����v�#��5ܧ��ܫwK�~�,�=����Si�[��Β��@v�5g�=7n_m6_M�zG�3F������b����>�U`ջY�E�t��D���������O���a-{���NG�̩�$?O׍�qVL%��]*��!�9�4�ڍ���R2k�['eJYh����p�g����n��_���>�:{�(MA_?/O�¬�f
�y�l�*���
��ۈ�4/��둯u��)�S0;�lU�a��I^�҈T�Y����qvq�y��(�۳�-;�rP���T�B<C+!kIEh� ��2��,L�-���M�m�E�tsP�����R�Ş,:����؏��`��� �G�,��i��VC^�G�.�Y�ָ�9;�P,�4�ֺt�hS��ǻ���W;L�����������<�͠��pqqY�X֛�\B��W�s��f2� �E�Ӭ�����D���U~������D�$�o�J�@�����m�y��?�b�O��z����=���?�w�#ӯ��ѯ������������_�������������������_�����������������������?��w�S!-��F�)e�ڒ(Y#�o2�ZH` !4H�.����X����j��*������ D��1g�K��qi�����"a��� �ϖ�s�Mgk�nwkk'�'�N�ff�6����M�L�jg��?�L�KT��#�g��s �t�����+t�+���?����ޭ�w�G�����5x՞��ˉ%m�����kg��x�Ӊf��{�����i�%]��6�Um�d�����m�fN�gE�[�N�E�M���!�����j]�,�J���v��}ߩ$��z��R�k�d���� �荓jn�i�4R���CE�	\<@�&��>���0kH�eR8Xs��}/�#�A�~\ei���\���,���a�׳0���/�(���2���i�M�F��x�|�1�`�H	K�k'*���b����W�$*��N�1��&M�F�IW�F��������K�5q�����>��9M|�{�v����ۋc�Q��"yms+����O�Y�O0�B����uS�l5Yx�_��Ǜ�T8��P�f��^�	'�Ƕ@�V�Α^B�D��5q֕w^z��>�{��>��Y���_����=__�%'��@��ٯ����|�[��@���? �~��-=�`�\�\���l���%Y����8����/�pO���	��KB������웩R2&i��?��z;�� ��&�I/0۴�Xƃvl�xª�-@�8�(S<�;�R��8g6�KW��t/|�6�K�=_�!.drTC�y4��`oZ�r5�e3?`���0J�5wbm�L�v��X�Rһ�� �^_͆M�"7�+�0�7�eF,$(ӯ�t�hY�D�L���T7a̑��<{/B�{�W�c�ҭC;���������\(,gډ�0�P��C�t�sr����}1ut���<0��+#���� 4{�{���kԚ8?j�ȼ3�h�c~p�;����,-�\�%��>G���~O��n��5���}�sk���9�d�V�o��qm��ʯ(��<�sx����,B�d�w?JQ�i#�T�	ZX|3�$�� R��0�ʋ�?@�1 �[�����k��t�%�����S��>*�`o%�_�p �n�:C��j�hҬ�Ӡ#!���.�R�X��B��N�0��c.��j�����p
��� ���/S�`�O�(�?����P��{ȭp럳"D�����*��4t�%�z�[� ��]���@���: ��F��򇪰�"p�w۷`��a���sQ����z�˺�d1�.y���b@SXI���p��wR����+��SOI�g[ �Jbf4�!�|�*�ISUA[�j�� H.o�ܔ�v$��0�g?���? 	�,U�G�-�-�C�#W}ߢ4z?[;75���ۖ>Z��c��\���NV�����@l��l�L�L���9]0�Y���8�bf[7�8fb�0XoM��B1�1��LB�������/��7K�"�u���q�V�����yBt�"D��ƅ"� Z�`�t��# W$��B���sq`1Z���2{��ob�����es{��Œ�Q��|�ǯ���I�"�	¢WBO>�{Nbt�����`�䓯�괘8���\8���+���n!o,�)�m����=�.����wk-.c��a�I�m���0?�\���O�Iԍ�� �Th�!*����D��»@�m
U�(1Q!9�L�]����cvZ<}��|S�fU� \�S�K3�F����o��jPX#ֱc�%�W֕�;t������,�zI}�tu2W�92���b��xr��.桟���}�M_�����R�xP�˯A��m�Q1u�[/Cq�\�*�\��Lt�?#w�F���w3��\ڪg(�oJ�Wh�ph+
�KNۈ�=��0˸Q���?"�:[Δ/r(d�!S���v��<R�F3	��((�o#�P�4�4/�Xܵ�U]1�� T�|�Ů��]�\��B�2�{p�P�67q��q��{��h�X�ΣI�}�v��>�����@x�Dy�g���֊+���)�6�I�
����A�d@� [Xl3:����	�C��P,I��qn5�4��AZ2G>��@e�v,�i����\�?L��� 8h�p����@���"��m�j�_ �)�Ƴ�NՒ��Յ��ZJ�R��	DC��c�TjA&�h�`����m��`�,{Y���a��s
�8��z���8���8G�Cu8 ѿ*�-�����[23�f3�62��R��tx0���,� �.��@qD�t*��q��| ��s.r��BLH� 	`�AQ��Cԩf 5�[;*��U�@/
��I��{�1��W2�|�0��@l�6�pi��0��l�ŏ��b���Sc�	�̺�����tp�x�;�9�$���S͎~]�<��=.4̒�.63��x-�d(\�/�\����aa|��oH���ꄪ��ￖ縶i���v�/�va���;��Zl.�ӄ�Г��_F9^� �b��?������zg��"��sMq�"T�T�߭Qא`t�_�����_��W)��"��Q�Y^�٧��'�Y���(�����N�,rnU�H�QΎ���hOYp��)|��r�˥rȱZu��\��wu"�s Vg��gw�m��A��X��vt�n�ϦNŧD�":>x�~�S��*��,v��+;;���kî���b��3f�����qe�osD�meT�l�mwS[hE�h0`f�im7ύ�c˯s�.¿����m밍-�ڎ߸��v_2S-X{�w�mr����m�W���Af=U�Hyx2��]%��W�µ����JR	��ީQu����{d��~pP(��q�]�O�DK� �\A���}
��# gF�A�!�� b,r�n�P����W��x��!��|w�e@��-��"Y��-�1 ��������yf�˓{�9ߵ�r�tq�{��Rޅ��|D��:/�i���@ �
a�P�0;Z�)I냵��4��7�M����d�w�Na�Z�v�_���3�Z��#���,��>�I*��D�H)3������$<l�"X��Yë� �o�|B�����F����C K������(ˉ(��F_:t`#�@���Lj��X��o�
XeP1tZ7�5}�ou�o�#k<��t�o]��-KW���>�ն��:GT�Z�(�uFǯŵ����!��������E���፞�ZM/K��<ǳ�g0��Sp�Yc
i'.�<�v�zHC��]��1�3���ބ�A�m�����Q�N*>�)�ʆ��"7�?��6�X��l�@V�	�h-�s�6��6�(��N�� �&�Lأ7�f��v:F~�I�N�����R'�5�{E�a��>�i��ǟ7ZɄ�>�<$d�����C���;����:�ζ=]�,���Z�h�y�[z~L�.TtP44	O�����<+I �YXP�Ǽ���A�4�������r"��}
ȗB�x��/�M�N��;S�SQxLT��V�r�����h|:n&��%��y��-��?$��Ah*�=v�H�g�ds�3i���LN���qQ��RۇbA�W��Koٺ&�"2cq�Yu��k�3qm�>�
^���@`Kk�XTr��H�jpF悴��yg��%�����<$`Q1k��0'-�<=`��S�0���I���p:U��Aa��^_�u�G�U;m*�4��,�S�n|`Y��q�Ow���5�� ��;�h��JmD�#Q+�����A���� �Yn�G+�/�Z�l���l�`�w��_P�|��ۘ�2^T~7��?�Wv����Y�%� �U��Z�W�:F��è>��Dh$�p�(9���FAE�;gK`��}���S�~�o_!$?�;�8 A�
��^{9YR<�)Y�Z�����(W����/�8W�ڏG�f*�W_���.E@���yS���@m&��(�1QI�l�/����tSrs�%5jՌ஋}c �o�9�偉��76^���#A?{�c�%C�K�OAI�+A��R����RW�
�W��D���e��k��(�6<1H����HJn?����>(�f��gN���J�#����M��R��^�y�YAO�?�Q8hӗ	a/�ڕ��JߝW5�6���©O�w�ى�cesy-�k�nZ&~��6MA��gű�		�= �2�\�jX��_�U�cY�.���kA�i�J�F�	�#:��Ŋ�z�{�Q�!<5+��/����M���F��\N%37Pէ��+
S7W;!�2�����0f�ǥw�.�
?�-�!�	�@P���]�@����x�@g0e�`? p�;����U��&2�/0m������J�W�M�1/1���{s(��s������|�b]A��lk[6jz���Α��ۃ]]3��A��ע�a>�[7�bS�7E��L�q�V�����1d��ܨ�͗���+V6�� �2�O[�z�7?�_X_�m ;�ѱ&;$k��ij	��Ą��'7�Wߗyncqяqy:#�(ii�D�97�i�=�O�f?�D��^���̼9��y�Nկ�;���[{ ����Y��_��מ��k���ɕ��~}�>:��8�=��b��BI2�д����j-���^��n�W}�0D#b�s�l�ke�~F�˵/����iL��Wq=�"�"���	d�KkR]��w�����`�A���,E`<��c�� wq��57�=d��&" ����4bC��kU�,~�L�&�;�>c%qKy�C�׋��] dT�}t�&Ō��l��g�jج�̙K���oH��AU��M���;u�oJ�����@���f6��Z���{���]դ�����������^�3x6^�������ɫ v/�ٻ��c����X��z�}���^ۤ��e�(���3���C�9��}�2��U�Ӝ���/��V�>��Ub��bFgw�j�]:D�y�K��	K���0�� 8?���q�&:_����� 9�G,e�pU�|�2|�<�
"�)�!�@��mc�9�\תM��cQ�
�y�U���"�uU0�(�a�L����ƣ0��|2�XS��>C�m&�r2(�{z{���áQ��o�yk�Ӥau 7��]���/��rp�'��0Y����R3�8��N�P;]���U��@^��2��Ȍvb��v{��|��Ҏ�)�Z5l�`��ZN1^0��
G�C��B;�X��v��=�'`Y�׫���$P��������ZvP����Q$XkXZ�a��t��P�0r�1-ڭ<��Mv|��բ:VǼj����<;u�,����!A�6���n����DX3�լ:���P���3�{����,:Y#A(�����h��0��AA����L���4p���t�j$&UJV9�xp߶��*���#�Xd�X�/���ۊ7𕀭�u�Z�A��6��塾�
�ɜ<\5�R{��m���wӠ�3�W�'V�����(�kG��h�R��y![q��`�ޛ"Gy�]R�������
�p��X0�=�@,A��O�?-ά5����4��J��I ���xA�����&+�P@}������y_V��5��W�(�1����JVfg{=���X�m-�ژv���X�'
�۱I�ă%Bb�Ɛ�w��bl_�Q;t$��(&|%��D�9�Z�lX�����ڼ�xN��h����
[�����V�U��KZ+�q���iݹa#_s��Ud�]�������49��+Ƀ1�]z�$��fO�=o8��(�>���k��?^�Zc�:Z���I����g����c0�<,r�m�������fV�(��Au@���t�G�J&!��W"U	Se|���oI�
wE76s��o��"�����R�O����
(�w.�����v��v���P$������Un���5fDg2z�.��۬as�;�'�PD��I�_Y�`G+�H��.i��d�n*�_͜<���%���h�3�5�� ZZ�����^��<1>����w�d魎��B�}�r:,~+�F�N-��p/��b��Cȶ���#�C�i&�nMn�B���<��Ş�Po�h���*�V+j=��BZ����5�_צ\=�ܿ�)�r�wvMT��Y	����J����?IL�g��Ѳ��h��ّ�5}�￞�:5��q��n��qԑY"D6tF��
*�G�忹�|RW�b�Ϙ �_p���{���FF�����/�����#�����������_�������������������_��������������������1�_����HFNq_��D��F���D�z�Qn�
Fr��#ie��ՐZ�O�6��a���=���#NY�:�!8�W^^~.��ki����j�e�ꠧi���nµ��cckw�򹵫m3�V��=���#����)z�:�.L��{�9J�x�y����_������&���|�e�Km+���Q��w�ӛ}kWv�D7�c��W����m��i[�*��^�un)c�G�}��p�z0��.K���a�_��'����������
���TJZ�~�ؓ�Zf^7������h;I��5�K�U�!.)C@ڎ�(��,�GB���o�3�F,�G]t�4�� ԋ)����*q����g�M��BB��)�=G�$�=��߳�V	�)�u|A9�ԙd!̲����`��j�"��x�:���=��A���J�:ŝ�&�M�PG#��7���KT�A�Ѽ��}���������?�h�~�����{�����0����uAŵ�����T����6�s"�F�w<���7C��ω�����L_�`�Y��^�|L/�e�U���s�G��.�?��B"����C�ȃ~�C����s�2��<�`}o��Vv&6+Q#�V/\&.��]�F(��� j����`����ʼ���q�?���0���ty�b�8��Yʆ��&
8=�}���QqJ�?֪&�����%d���o�����H@ s?���VA���zWW��2"{�P;����hX�Rj�`�������`��"�N>�mk�D���z<av���"�����μ
`%7|s�Y`� �3uw{�����Y�R�D/q�c���?�����I��:Ţ��𖠾�ȹf��-�d�|�R&@ڜ>�X��B�@v��5xv���d�*n_-d��jE��V_����<�S23�H#8'���5T�K$���Ad�JV�3�s-Be�������L��@mЃ@�j�b�0��|���.�C/7�f�!aqL������tio5=��u��~��e��ɲ�u~�<,/L8��p`�b���-�-����i3x�SX�Y�3�T�54Y4(�}s��p1�6A@�Rb_*��q�)����K��k����x�h�����wפ���ᛜ-��L�K���mf��Af:�f^	�s0)��іS�=lD| ���֩cx~hcc*�f1��4`k!�i�Y�������9K�=�#�H������?#��k�M7���c	*�Y�r{q�� 5{�Mc�x'�w��;[h��;!Qw ���$R��qpE�x�;T�R����[�����zI��AR���f�6��2��h�C��������ױ��y�L,<,��+�~2��X��+�[f�C�SaQ_�J�y]�pL[:���{�K�A`�?��AnQ36��l�^�_o��f烌=y�/kkbm��s��?��sD-�����f	I�B�2�
��ɶ�FaC���iX�k�퉶��-e�����]���p9f������X8���q!}ęU�<�c��j�-�Ap���� Y�)&B��(�&�/V��n�pV�F��h���rmJA�i��p���}�笳crV��l�ڻ�3q�b2��z��V!0dWc�g��Ԋ"��!�)�>.��(� }��M�V��F�M7�]FE�y��ܛ)�S33׍�~��;�	�0W�BSjJ�{R�16����]oh�*��d�܎Ql�����#��t-N�s���^cH�k�*�ie��2��l&!�%w�栯p��r$IhAB@U+�c����a�T^)T��
���nH��C�WB.��n7F��-��*|MO���*���lŇsԚ����y>��}�Q�*��:jY��Քw�Q�0�04>udC+4�sn\�-�и|�pUY�QM3,%��ҙ�`.��=^%�@��5$�y�22jp�E2�}@��!��)��� ��p:#��I��%;Ґ1�(�2�}�Ol�^��Y}<�a���uSZ���Pp�Lv�W,�\�+��������pO�K��w�,T����%��w㗋�y�E��.R���ƅ�k�Bv �}\"YO�I$��76�c��w�X�vZ��#�"r�Yi�?�]c�d_l�2�����!J���O�CkZ(��������;;XK���Q&X����+��p��FMJ(��XČ$0�=׎w(`!���J�K���e9e9�*YF��`�jW�q���X$Y�IC4?`}��,u0�#1F���\C2����������z� M�I,��������K��{��9�skFk
4�����%���Ș}U3�)ٟP6f�%r��M�|��\y1�!2@���d҉�E9��'Dp�6����GH� �b�6&�:( Rk#J�`0�����C�ty�ʐ�Q�y�	�n�+ƀ(�XV�<���zq?
���NM�n��X�	�*�u����=�
��O-u�#�3�'?G5'����N0 r�J��P����>�ز�P��x��O���? GB;�yzp�|5g�d�~�� ��cw� R�����;�b�E���u��Q������.�T��T�4ޗ�/	W+N=vX#��������w�Y�?V��^����פ��T� 88�kև����Vn,�0���Wc��A�Ľ�h�J�_ҏ�S�'3�~*l���L� zr����enC쯎��|΀.���-�r��I�{�~>��cܫ��q�=Z�<:ec����}��w�,��q� ��oڦ��퐣�ox�\g��'>��j[7Hvj[;";WoX&�V7������\�ܳM��:����v��v�v����V�Vo��K��bۺz�v�no���[�잶��]9L����^:�I��ƛ���W�iʺ����V�c>�7`��H��a��L�)QQ��ҥrg�tp�8%��H��Whv�����66 ~��c��U;K��6��A�?���8�����/��ٖl�a��a]�ĐTCyr�<����^P�(�q0=�����[AP� vi��>h\���r�no��;�%����پ��R7�\��ֳ�r�Qs��=�X�����B����@d(h��Y��>�i*�����ő��l�`����%��eΙ��*ӳ��j��s�ϔ�ژ�]j9��B
,}��h���1��A�/���>���p9"Ze���Wg=�e	!\ K���ʐ�(�3T�I�3}�v�J�3a��i�j����M���Ɖ��Ϫן�W�L4�,e���ǿ��Mg}�^����y���ܼ1�T+�	�h�Ǆ��kLc� o���PJ˸�a�s?��;��c>��e�.	j��Q����x�u�Ig��<c̱	<)ex*�x�E<����$����ʍޏ1NZ:�V	��
���H� fA1Q��ՃZ�7��4{d�"�fʥ_���h'RT8Q��~tsLZl������?V��ϭЇǛ)�jKxI3M���
�l�����^���L��2ע��V^������*��{:�zV>����tJ����Rr^��	���M�el�
N �1�ع	��{0�ٌ���_Q&z$\]q���Zt���XD;7�ç��-P `��7!�;:�-�*�#}��m+�����V���:u|a�@��'$�3l�����7$'T�����W��
�W!u�5ܚ��]-�Ͳ��w���nl�xӑ�/q�+47W�0G��
�X��G�/ђp���IH��4��Qrɿ��m�udܑSz��!�\mH��nܦ����w��ӳPp��Iu�s�1+�A���&���S r���YxT&�!�K-��d�F�^�N��u��|"��׾�l*t�o��	����V>{��f7���w��JX��yP ����o�ɰ�EÅ���6�%�Q#�C�6�b���%lp@���	TT]��m��*� �`�"X�O�&�g��5��퓳aC������̹JʻV�^�}&������Y�G��,-�-A���`T�H��S��_zI;a�Q�3�z��I����W��AU4���3YNP����0�m0IܶzMi���Fғ��i�2����TA��I�
)���۟A��9�����䡁���'�&<2$�tb�M:z[`�%+)FX���7�*���
����qa��6��I��GQ�Ȟ[�O�	���cz�FN&�eѤ��_@�������&�ՠ�U8�o�����*T��sk�����Fn�K%��32\�
b*B#��r�k��p��8ɯ�m� �;\m�cmC�</�ӫ���Wɧ�C���Y1 �y���*oV�uy��>ɰ<o3���I�y��j�	�R
[���+,������kS!���{a���OUm>�)?�8��Nf\jpt:둦4�$x��F@5�� sh5s[G���g��~]a�H��K1�숎���o4V��3_^
�ت�o3Q�h���+�s�o7�/
�SڞKn�ӄ[�T�m��iS���Fh�	8���xjV��#���thl=�k�x�>��Q1JU��P��_�}��7�P�l�:����������(^?{`�^�i-�)<f�i��d��ٝ��Zޮ`�\N�c�וgf>�	����K���FYYC����+��U��{��g�����ge�7�KCm��^~\؎����������?��Ï�x敝�c�G\�����8�eHE�MY�p�FV	���,�ha����J4��c���%7'��c�gß��C��W�N8z���s�1�#���6�^�0FL�� _&h��Ƨ: 2�!Pvx,��l�"X�B���&�H��_��� �ҭ(�wI\�,&���uc \f(B�Ј��|�<���v��W�)�Y3W�H�ȠY�8^��a�X�xY� 8�Yǧ���$ ��yA���t��-Q>�j��8�U��O�O�i�Z�=%u�3�b��S��c�.C�$j���s��x��}_��8C��Ea�B�Z���2w�x��i��e���8�C���<������%`�0H
3 ؀N�0�B���`7�,�/
�$T'�ձ>�U3*{��wQ8�~���ۯHg�n��"ܸ�j��{j	.#���҈�z�D�6e:9^ПuD�3�AK�ǒ4�}
𧤮�c���B��x�hg%f'����}��

\>�'�K\�A;�w̛����ѤiTUo^���i�6yT����;SV����@kGa�������A]F`HQ/T�lq��~[�?��{z?�ԥ`z�Vw����N�Ԡ�j��������^�|��Ml,;�E*�UǢ����U`l�͈<�������.گO��C�2���;Q�J���摉(�"y �7�(#���
Iw�{
Q�ި|�V8��$xD y�5!6�f_j#�޷$�*�������9b�~��A#�!Ǽ*wv�WB��n���EyE4�T�Z�����d���8%�*�w�" <B���G�O�ï�*�`R}���B���$_��ӳ�ԣ���P=���]�?����h�43�`�dQ3��,�!��dGų���l]��;@��Ph��?�0��c)�AW�(����p�ڋw�n�I��뙈�Qq��d���K�����	D�*̎�N�׋�,a�s���,�+,��'Y��U����(LJBB�Eޘ�q�%"�;�VBƦ�۸�����q�%�Z�v�{�F��,�n�����^Y�/�6�Ԍ�8z��S��'pS90�����.��T�%��zGk&art���U)3�����`_�i���m��"���S	9WO�##��P��n�@,kE���p{X�>���C�h��z��i��&cĭ
v������<��<MD�,t�QԳZ^;q�f�J�z�$K���q��@n���j�\���u'�WWQ�ѿ��L�M�s����l_KRIrp��73�q��F���W�����BN�H�?������0����]�K�x���Q�߮U2�!B��ϗv/��������o����o����o����o����o����o����o����o��E��� �  