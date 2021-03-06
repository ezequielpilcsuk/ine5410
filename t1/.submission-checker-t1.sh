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
� �ɢ[ �=�v�8������-�R,���X-w�mu�O;v�v������ds#���si̜}ڇ����V�B$x��x�N��$��B�PU�* *�atN����7_����bk�v_luԿ����������|���M���	Ed�둔<�0rB�q&��Õ��?}�X���O¯���ck�Q���8#ھv����(���i�omu�C:�GB��'�����s�[;w��ګ���r��?8<��/����_���7��������f���`��ݽ_��[5T��H}Y����dmD�ּ�dR�q���FH�N�N�GF~��pB�,����,$m�
����=��6�=ZsǤ�X�K�":��I���_�yE'$r�ԟG-B�o䓩�d>%3>��={V�fFZ��%��K�&��MH%�%�g��%�*�(%mGe5|�B��_9��������F��crkc��+�Ԥ����lOipA��б�������ϟo<��y��_��dw`�>C3 ��_�����?��pu�.5�^�a�z��=��#н	��@�*�|4cJG���}&���_��й��d�é�}D,:b_�'����Y��� r}���\��y��QL7��6�{C��F���EԋH�"�����G�a�q�i.�����'O�,w��0�u��C �=&]�m��K���v-���^��YހF��c3~p�Ϻ�w���ˍ��]�Z��$K�������]F � �zR�ԕt*1a5kޖP⦓���Qe����Z-�"�)�����Y�[�yu��$Ψ��C]�t6�e�#}�:�x���A�g�6T�5�ă� ��Y>�j�gO}٭[u�Vǳ!����1F����$Ј���Q�*WV�H6Q��1,�_�F�V9��=�<\/�������o�-�z��[|�֗����Q��LE�2��|2��0�) b��a�H>˵�1,7�_�����|��}�鬭]|k�Ɏf(j�r���x��Lܑ�A;.{vy/}����������f��ou���<Oܱ7�cb��=<��=;>���g?��~�����va��CԞ��p2��]������R�A7�@�+V3;:�]ύ`�� /��Ibճz�+���#���c�4����}�����6F���9�`�)����4��Ј�K�z�#� ���PoF��ډ��6*c��{�{�%KP�6�g�z`$v
���l�Z3Wz͵G[�'~����^�(��Ϸ6_d�������G3ݮ�[n'i�e`i`a�.M��L(����4<���1��M��{��Eg]��}�Y0�9�s{�D�=V����I,�⧃�A3Y��ҮW�ѭm�^��U���Ht�Ϩ�;#@�9S�Ҩ���w8�����3h١UCE�L̂uC�	��[-������`m#�ʉ8T}��-���&F��þ	⢸O��Y64�l�'#[�cy͘4�����J�j?h�7ڤ�,��	�٪��F�q#@���e���V�n�a��G�#.���/�-�I-E3����R������T,���.e	����~b�^J�0 k����~�)"1!l	hcE�)'f�t�[A��êr[�Ӎ)|��F1��WG�ǰR����D����i#�w�c�^��OO�;6��8���hO\��<�����Z� �8]���>
V�b58�m]N�~�`	���*i��^pn÷�H���,�ɷo�o��.7X7֔�=�d���M���e�B��";"�����W����ף�(^bXLYp���X(�0�#�#W��W�#s<���h���:�+i��Ih��hy�6�TY,l<e��m'L�I@��G���h�W7	��	�g�I��ۺ��F�Ɋb�QC��8��B��˙��F[w]W'@J���\$�ev�h�����ܘ)�Y��.��(�?3��.D�'�0��`�O�u�{����W"�8������-���O�7z���ѱز����l�je_�a{L�^��a%J&���F��t����(d���~��<�Z��A�t�,�o@���������&�$��<��D����#w<Pަ����v��Dl�N%�NO'�K��z[�����XDS�U��T��}ݨ���L���˼�Ǵ�OVY��G������������c����������%��Y�?��������]�B���_-�V]F���P�~��ѻ��5u�÷��ªGm	�+:����@�a;ÿ�݀�J:q>Бe"H���f��>�N<jl�%Y8�]��-��N'Ň����*�C'PH�'0줛!d	�a��?�t2jX��VE(�k}�^�}E[����(���d����%���+u�$O�)(nj��i��`�C5+��b�F�ly�����S'��� �v?&��)2k^��&�������V(�Z3�QJi�ֱ�B!��T|G:npF�7�elYp:�,DΨx:T�<7��hg�j��;A2�;+��m�d��,&)3�s��Tw{��u��o]�r������Q�u^lle�?�~���I��ՙ�����=�G0�p��Eb?5U��T��3��sd*>j�,�'�SN~��!������I>#�������}��_n�/��𒸭�F�j��ׁ3�/����{{0�6Q��h�?��m����~s�jp���_��������g��>���;��t�z�mX�?�@���m���{Z�����������><�}�Ǵ�{u���`w?w�����oL�8Ԩ�RcsӅ!��=4h���a��~2��U��ԫ�9B��8ի�Q�f�sSũW(�Z-L��7�Mڒ�N��%�a�,�'�lW��L6�f��Dh	��YhBNp�\k�u}��k@���2}{а3@����4��&�s��V�)��G#��+�NI�uL�c���S=JL��4�U@�$Uу�p�,HQg"ܔe��+a�!� !����H�e�?���o�Q��C�����'���&f��5VDh���"��hފ������MU�	�~ihs�6�͌�J�9>V��c6ۂO�����2���Y����Bѣ��ǔe{��-r��	^��2�|�|���q=<i^���PfNC��L��:�PX�6X⏽C/.rC;��y�W4)E_�C�E�P�ZQ�3��	��Gm�[�������)ph�]o�c"���Jv��h*C���T���K�X�v����҉�$������#悸F�ı�NA.�2yO?�Q.$R�%r��n���h�9]҉�|}6xc��&���D����dW�F�,S�:'��ǿa����ا���7K�۷�[�C4���"�e2��ioB �4lӢ��-0/���Zɴ�>�fR䞈�)ge%�xE#pA+�3�:�|�`��C��|�¦,���⹦L�if����"0v/���t�`��'i4Lֱiih/h��,	ZDA��^�^�Y���Ib	�;�H�'�c�m�q,��e24���Q���a�QH�Y�<�@�=t���E�s����_�;©�{�ob4{��~���g'��>��������'�����X��3�g�C�r����!�|¬y
2��/���n��#Ӿ�c����'�iI��*T�u�}v�(>)���_���x8�� 8'���OK�Q���x��aZ���V W	Ā#��Ә�O����>�$CF�å����v�@TZ�}����6Ɏ��S�����m�D=������#g�.�4�{�y<mN��6a�ɒ��t���&�H�$����2Q���a�X�d^��f�ٖ�q������b�e�� ����j��rb)��!bъ�G#�3�1X��f�z���4�L7��8x��%O񱎗�=��^���m`iZZ�ʛ�����A� Fn��כ��%�>#��a��ӳ�CPI3W��±�lIz���-%�j#l��׉���8V���������T1���:|�x�8�� +��S�]E��iݶ,e���;�9Yx�x�a��@����r�0��ĩ*�e��NS�Eť/1ST&�u��f��D2��"�����ηAf�AX�� ���"C�'Fٍ�f���4i���Q	Mu"���%�/�p��ˣ�+��
�y������y�C���B(Ӱp�~��s2u�$�a���w�Y�Gq��"����X���8�*/(���Z���<��RX>v�b�#|���%�ޠ0�N�{P!��)o��Zjd����r3�ïE�b���%�Ы��lĂ8��@�B����a,V�W�,��oֱ�y��t��l�}I-c��2Ã����0�f˯x(��l��v�|�� ��6��۔�y$
�}�d�ݒF	��>؈��H��M���t�'>&N����)\��*۝��𲕼���P��ΰ"��dŇ[��k�~a��D���eT���U�.�@1R'j��K|fqs3u�ޜ5�!eQh�|<�/�<O�iN�n`��=��9��Z�l#^�B�6q�"�a.~n���$&��8mȞV\��R"9˨�EG�"��5�բPH�zcJ���\o��R�d�IMFHy��)[�g͹��0ޅH05�~޴�n���k��~i��q�4U�|'EO�f�]0�<���*�b2>+�:���0=S�y�ds���{0�R_r58L�Ō�� O����E�7���e��}1C�/���1'��#v��4��e���*a��t{��ֲ�2c.c]�ک��v8�Ni� ��U�Q;�GL@�-����0��������.(�}����X3�dJ(��G�wd��)�H�vDcP��a�)�0@]Nm5a�>���Ɋ�cۘ�~����J�#�$�J���=���#y8��b	l6��\'�oj2e#�w��������,Y��2�m0�2%�ߴ����qNo� G��]u�fޣ�^�ױ]],$9��M���?�F���ES�� �.0�/�Xp�E���	 ��tf:� �wPJ7R[,�<�E�]9��H|C���d_�1��Y���8Wq�nn�5?!�ϝ4��j�d��++$�M�B����u2nX���(�>�}�鷭(;!�mPyj�6�ے������ڟ�3�n@<�
"r/����K���r��� � V�To�(�)�b�S�D	��e>�E���*�_�cx��R05Ei%7�3)�j���ɸʵ������-EE�}���ۨ�C�w4�1�x?��%-Hx�U�RkW��x+��ww�SUIg�������-$\� {|w�/G��7|������ qs�ã�Ũ�����>S��Fj��*���S,#�!��лyC@X����R!f{�{��赛c6t���2J2�ȗ�a�q�E��BK	�2�s�VSCة��qs"w��3y�[	��v;gn�X�̄�{	�߳��E@���7h�����it9j5��ڦx~>B����߱~f_J���1gnqf)RǙ�U.}5{��n%�d:��O-��%���F7�!�2�W�|&FIϤ�"BF,.�B�O牍	�_�1��g[��T͎�99pS}�%�����'��q��y(�3�Fd�3TJߡ�� ���#ی�6�Z�O��S��ʇ�0V~��F��˖w>�I�����t^R��w.SW���f ��ry�!V�Ǣp��KÜZ(�Jp1��^��&Fd!�
�`ws����dpv�r���,�*�鑵5�s��ˌ5!�YEu�^�Z@�I�;˚�zIgȾw�Tw�=8��
�T��[u�*��*���Cd��/,�3����I�*�"�B���zt�v6�`�Y�����o�z�^$�i����ajG!u�1O7�"�UH�h�~��(��ԙD��V��մ ]z�gx�-�T�V&P�o_�q_����k��u���m>���a����/�/w_�L�X䗠�^���`�G�|��L��W��J���F��+Og��a��UQ�$��V�Wl� �l�,H3�I�Z�d��ۺ����])���$��,�R��J�	P�t%b>��ٯY�KI]k��[,Nӱ���	A��mYŏl��q��,��Ҍ;ICζ>�&{?U�o�LX��� �M/�h�UY��po�ne��	�YZ,M���Z�yo�R���{���O������ʾ�w��֣����-]�_�]��[�5�UJ�2�4X��֜τ�#�t��e|)�]��xVg�������Yك(�%	Nćԅ�x�")���D�O�AU�f��2�u��%}�Oq���t�	/���˙%�y���|P+c��|F&�;M���)HE�����o>��;N {���X �֙g������}��S���ܵ2�V�g:د�	kq��d�3B�������7R���:&�VZ�1ݭPT�G_�Δ�Z8
��_� IL�B�����9TҒ����o{G��m|6,K�r��$��H�E:9�諒�L�7�;�9~(��<��4ӇL<�'�/}�?��@�<�$����a�G,��v�] �t��ժ�d_����be�m�*��t�@���ԝ��ʟo��vL�X|ψF���.ކj`�\/K�(�����Da&�Ȟ4�}��V>�e�J߇s;��R`�U?��͹�SZUÒ|g��m�oQ��?��8yW����mllL���p��烔���=Y�z�: J�A]�Ze~}����78�n[f��#�8��x3 k7�>�BN��~ПN��ec�a���z�t�"�#����3<J�'�Z�v�ĵ`�/����0�cB�gf� �e�r�ܸ	rCA�ݛ@�<F��v��C	��Ǭ�M���v!T��m�	���[�4D����`Lȝ���aH�.2�s������J`��6�[�+Uŋ����.r%�O�����2�%_�p��^K�\�:#=o���A�,f6�<����o���;�څF�-��/Er��t?,T1՗xTb�2kL���R�T��B/{�m�rӘ~Q�;K]��Sw�i3}R�����
̫�^�J�@��A�3�A~m�^��40
���|o�z���z|�?�rJ�:
j�Q$��*��F$$�g�)_lV�aVիu�Ap�2f/�b@k�աUյh�����*j9{�
D]H�����Q,"�<�|������a$�Y �ibl��V�W��k:h�-��vI��X4�U[�V7�a:�*W�ˊ�ȭ`6��˻#��YTgW��D�u�a�d3���n\G���ul���:�����M7���p:��:?�郔���������yc�����gF?WsB�a����1q]�i���Ms\W_1�u �fy=��ƹ������F#�i�k�zV� U�]3e�g55h�t�A������F��+Ӑ��{LŜ��L�ZɄΠ���l�� J&~�< ʆ^�n>�����9uEO%������Yk�Ve��'yW�>�Bg�޿�d������ߍ��ݹ�����Υ?�\�����I2�^��~�g���b����Y*�9+Gn�_
^h�;!�����O/��8�<@\�X�םq6m��l7��7N�xpgg�����\y�{�u��T��3~�Ss��[nĎ�݁?l�Ya��_q��y`!~� /7�\�d�?�-<В-k\|�`[���nQ=�I�,��S���3��,���d�j|��؅�0K[�g'O�v���'O�a*�8�ph9��L�%	��:=��^��h�R����E�a��[���M�3HG��D�=�>���0��A�Y.^&x>ܢ�u^�y)��A1��,�c���ݍ����m���aJ���_:��!��(�?�.x4}�_S0��G�u�W�[:�y0���W��׭22��7�0�l��A6�h��H����/��Y*he����
��;��뇬��������@��p��#f~����L~GS�
�L�r�1�7ҫ�aL%v���X��.�i�������%�#x� ���?�m�o��g�oYz�dX�~? <�Ab�^�|,|0�<���ƉXě��e	��@&� {�0IRi���&pG|�� r�M������6
�1q� ���L�T,pS#�rؗxؒ��-f y���8&��Xs�ؽ��!x-).'�:>�_�2ۖ��I��c�NDj�c��y�8a�l������ZT�U�b\��6t [�tP�䢠/��;��}�ex+�F�W@��0�hH+��_�!��q�G��T�yQ��2�G�"�l.p镢�<�����Y�_��+?I'�c��HE[9���]�`����;g�����9;�9�aG���#��
���]a_���t�ϸJW��[c��hII�>�ZĖ�Lq3���x����������8I5��&�J�(��t��q�&@�1hD燎ۑ3���jd�)"�ɧ�e�`���^n�@��T�)ת���� �.Pd\�[C�G�נ�,��*
���B���(�A2�a�pti���a T��:�8�sk���$�Yُ`�������7F1�A�l�0��m��B<�K�6��d㶠�Rs���>�`V�p�A��V����,V:�������Ƶe���~�W���
G\�_>)J�<���=)pI8���eTTY)�嬷s���S��y��h��w��T{�����/=�Kn�J��脬YA]Tw���n�@_ �J�=��`���xz���O�*�7N8�m��z�/y�e���1a��tF�-.�4����rӅ�6��)c�bBk��1Ճ��{���¸�?W�Wt�"�*=B_���������o�B~���ԟO+���F�����b���e�F����/���CC~�W��rY��C5�yZ��;�������s
jG���[���!��H�p	0]���.��	����rA�T���B���猓-X8��,��^�,�d���fA9�r��H��iW�D��j�rA�ך�k�|�0M��戏l����d\r���>�໸��FM1y�p=��%έt�4��}pR/��B����)ǝ�M p�PҬa�Zy��^MN> �Ol}p˧��]�WZ9�3��V�b�1!�r��Z�ȫ�+|k���<3�C�mI��b�pJH�QUJA�@Р�]�8�����jp��V���#��UZ�1ns��x�������F��^و����ǣHe5�)s�Rc�*��ff�E�[SGv�J�(���G�����JծI9�]y�ڛ
�+�V"�X�ϵ�_�q�%�YWɬ���g�Գk�z�F��x����#���(W**S�~��< �������-�2��C�����|� UYh0�(.���#l-�3�d<U ���M��]�aU:����ޟ�aX㚀קAU<�0�k�@-��Fr���G�����X+�SsY{
���R<��E���M�:���P���vG����Wn0�5� Չܠ�͚���֩jEW�i߳\]�T����� H��V�n�y���b1�^�>���*&���At�8��]�Zb�X�SJ9КA;�c@�;�+��*�a�
0o��
G���S�et߼�n���� �kDL�Zm)O㷕�~éJ���Y}�{�V���"�H;�1/F�Y���C7����mT��7������<��wqq`�����ӝ�MӼ|�R��,��۸a��_{ح��W7��|������|�ց4{��Uv�$w^~)����"I��2�UN����Q������q�|��z��2����_���
x$@��g�O�1�&�q�'"�v;$U�+���2v"T̙�p����"��,����oE.�4�-I���P�VP���e :<�0�( ���.�N!H����b_��&�0>�i?�8Pa�eh�Ӯ��0�����%��'lŏ��0�Yk,F'7;��	�g'�dg,�N�q�v�{�|�
��8ZJrc�G{(���N]��T������GG{���ߧ��Y\q.<�e.��9�1����5c�b�Tk
D��<=ۅ�^\��w���
�(�f�0�:�v�Qd�"��ɸ�jC��,��� �d
��mx�~II��ۨ�=<)e��xQ�y����N�ް�T;�-OX'_��|�x�d�Iʖ�j�ƒ��W �ҙ-�:i9d��;K�OU�,S3�}�"�<���g:��$�|L�����/Xz<@���BC�Op���sRX��I��R ����~yr��&6c�BmP"$*l�L��1!g������W�v�bL;�*���rr% [�H��[\��;8k�~`��Lϖ�(�u�pA4s��Zhkk���7��-�Ej��◮�3��T��o�;�z�������X12I�؂��ĮD}�YC)����g�7D�?e�-4��9���`�~�9��A'���5ʕx[�����]OH��H�v^�a�*'���+$_��Ѯ���H�R� 2E|&�c�:�HPL���;�ˠ�������6�ev�z�n� 5�%uA]۔Dl���u'�f���}�k��%3�
�e�ȿ,��ᛀ�%�w`��5�@�ſZVI#�g�]�6ė���g;�4L�Qۦ)l��a��ſ�-��В��i �I��T�#�3�3|I�E1��lB��;�8L��㘺�HKd0#G�x[&T���+�t!�Mf�����v�( x�5vTF�V`f����g컠��Ŗq͍�h�NZ�\05�=��B��W�S��a˔g��L	�j��h�+>7�D�X� ���Ӝ�X�ʦu'@kb5��y>y�tZ'�4�@\2+�`��Z�_S��*ƇU�	�C	���d>)p'�}0C�F�a��FT��A�m�-�q��7ɀ&��>�ȩF7Mso ��$���z�'O�7�AȬ[YJ��j뼒�<��f%%�eT:L���
*�,dג�'�B������riX}Ӳ�v��z�A����E#���y��y��y��y��y��y��y��y��y��y��y�����_"%� �  