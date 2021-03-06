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
� rû[ �<�r�F�~�bLQI�E�dK�lY�mdJk�qN�
jIĸ���Ǥ�a+[uNm�8���=3�� �8�S[k�-���OOOϐ���֭?�jõ��έ�k���u������������ڝ�V�w���8��+#r���.�[����R�G�g���v�o������\����d�[jE���*����ڿ��n�"�O����?��k�[�ۺ��T9=zܯv�ǃ��A��UO^G��������[ʓ����o�՞��CT�T�Ik���o$i���ƶ����X�rI���H����S	m�|R����
���O1 ދ��7��L�Ƥ� �FS�"fL=R9�����/�M"�a^5	}P��C������4M�@�R^��	�s,�d��6!7b<a}$�Z%cD�yUs�7�T�	dw�I�r����d)c��7������H�&,�>�b�w7�����֗��Y���W�>?x<�O^�0$^&��
��WD� ��U���X{f���N�#~�����*{�9y�ь3/��f�7�w�/B:a���\�"���C��؎t$F��� �<�*sq���p���SƱk�n���F̍H�N~�G��GC��_�M�"�`
�����õ��jg�"tq���:&����8e��h۩�,�Jl<�,������1'Q�F��j���nt����<�~�=o�b@X ���z�VM0�k�]M�ꈛ�![�'(+"�])J� �3>����`��(��O����dT�>�Ȑ�ũ"��yax�.g� ՝���3_ �, �y�����!�&b�T�V�^�����@B�����I�(�j���A_\��H�w�I�НR� ��_"F�Wѷ@��������ʺ���4	�tU��QZ�>���2Ҟ��e&f&�<bxr�8���R����5y� �Z! S���Zk�[����
�/
EY�3�l����e��ԴM�~8�oom-���[۳����e��ך5vM6&���������s}48=�ѿ�ue^[0xC(k�k�1D��ad�`�M�sm�tcd�R7ӣ�r��Q�1�A���W�S.=�,���6���J_&A��o�@��siek�_�l� ���~�� !���a)Jwԕ��xlD|K��+�<�-������|�Z"Y�jaϯ͠E�sH���H���G���OX>̴�?AP�i=;z:$��cy�����{���6V�sh[�Or+� ��g��)�"8:��$y?p�Í+�]�ưjE5��zH�f	+�����}U3}�Z�4�bW7��-�5��z�����$�S��2����ϧAȂ��1�NVG�4W�J�����ӹq����H*F�.��6o���\��Vca|i����ص|�7>	������5���u�_���q�n�+��4���`����l�i[�6�:���.�Ů��m��3=߇-�;��Ji�Z�tD�4Y<������X�t%��@ąW9�o��g�A�# �T���	��FD �1D�B�F���`0��v'?1h	�&i��P@�ӣ!�vp���纾��Y���g{�ẑ�(ʏ���5-P���XĽӣej(��<p�2�/��飈�ɵ�P-E��K6]�8LTJ��g�{2��Y��v!���;��
��O�YM
�M{�U1�� �,<^��*�sd�gn1A�<(0�x��%׎O�Ġ6�X�Tz�
*�r����	���͐�t��`�&)ŒB�H@UZ���;�#p��OR�X��!7��E�8R=HN�~�.ތI�6v�:�ˇ�^P��*�'w��|.�k,*$�8Ѐ47ǲK*�����V�ue=ĲK��������Z��9��Tv��c�ˢ�SM�VY�����V~R�e\�no�0` ���+	�B��h�",!����n�6We+�t�*eJ� 16l/d��$�7�c*E��|��*^�aR&���ra�MM�2��v�&Ã�͛���N�u\��
����p�*	)���J���sr�O�~�~��	�'SwD��]6:�l4&�{�I�$�9'�N����x�.��xP��Pbx�h��sR����$Xȥ�F�)��2��p�Ao�>I8Z�B�����/(����ZB�|qL�Ai�l���a�~�VJE�)cDf$��w�n=Àы7��
SzM��tԔԉ�
�LY���j�V��<c�D�B�XE���ʹ&�x��W�/�XI����(�� ���`�K�F�7��c�JPt��	�w�P&g�����7�B\M�i=kY��o��-e&��630;�',B��!�.��OF'ã�&&ꙓ%���Nu��l�R�r���	J��s��2$�
 %kb)X�-���$d��P�O�����M�>�,x�R�1��>�<5u��ҰG~(�t���Yg�8��>��y������	��yZWy�b��~DqVrT��̺ 'C�<��
��3|;MK
��ə��e�E�H�B�A�^O�9>��&�~y�+كǠ�9�HJW'�	�}���F�g�u��#��wW��et�*O�*O,{�����r�wMAn�!Y7���%���g�g�j�Ez]��_�%��*�/�k�'���#jv4x��/W������#�@�R�c����#��ʙQ�2��l~OFd���b*R[L�o��~n|��6hP�K˝�C%��R��_荐w�V�P�7x�Zx�M�^PӷG|�O�Jic� ����˂on���� =zuΧ��f箶�$ݮ�������4Ɏ�ف��v��u�w�dK۹��[���[���:[[Ֆ����vo�����.�v�����Զ�n�ۖ�u8do����W%{Jȴ~��,��bj���[��O��~%��q1�@d?)Z�J��\z9I�@�$'��,���\�=��� ,L�'��sI޴�6�C���p���Z?���I��1�?��f���v�0��)���]{�7���O���� �ߡ;PVQ ��w���Qm�i�����{����;�3o��)]�'R���y�i��Y���7��X=�#�h@�#U��(���9����_>�-����2��e��M�D�yn�����H��2�B<NU�Ws���LV�zN.���P�/��ƒ���m`�}K� _,@�Ĩ������s^�HB,\ir��/����i�S�e�<_H��X^�C	��|�d����0�A�Ɏ��������~�S_ٵ����翶z_��+�;=��'*���)I�!̇��2�I ���R��:���'ȹN_��~�M� ��w���F=�]���%�x�g y)L<�.<'Dy'��.VHC���r�b���嵹�� ���Q %^����W��o���Y�Mj� �ͨK����-ɔT9rQ�^�]�d�l/nr1b�[���Ջ��j�ȴ(����=�%�e?P�V�6l~P�n���/���dqv&�׋�¯��/;�!���Ǫ�;�����r��\�[�K�b�����ё� ���eLl˱�p�:7;!R���6b���ɽHuu�a��\���`b4E�������h ���?���hZ���|��m��N�V��g�Ar��ĵ	��0�f6_�����eW,O���B^������f�����6<ᇻ��-���{.%���:�S@���\3��MA4i�����-$;|?�HJ�4�"�):O�t^����'){lc�!Iֱ�,[��)��/v��^hPw\C�u;�t|f�\(
K'��P"v�����S"|!������4kk�+���tܼ�� y�[�s�x<�C�F��{S��l+7cM_u{ې��\�P"�.����<�k�E�	=f=#LV$�+��r�a��F�`�.��������a��E�G pk4I���&��J7�nR����|��l&�����?�s�J{�U�@�͎4m�����V�X'f����O��
�D�Cr�|~���!��b��6W�[d��Z?�z��᫂
;�os&���nV'���$��j�,���fْ�@��P%��+�~?j	ˠ��d�+�%.�����A������������3�dx<Lp$G.F�\^���Քb	�E��T�p��P#��)��#����0��%>���*�&������!cJK�����ɞ�MJP7����sF�3G��AV
sU�9;�!�#�k��UR���Zϲ���w�I�a{��tz�����~�w�����p9'�Clv	k�um�m�y�Q{��O���'�G���wa5 �<jQ�Z���[]<c���&y��/%+<�c�X#�C�)Ch >�P�4~t���[*РW�z�w˫��nS��$qN�ʚ`�X8�s^%��!�x��
��x%�p�fv�}A,3_A���2��O�(΃�q���bǠ�Ш��ҶV�lɠ�h�9�G��_a������Ko)N�	�d;W�R�����K�:�B�2�!����^>8�q}���؇��c˰��1Q�EK��Fp��o���ÀM�W�_�XTJ]@�YlE�?7��߁�- ��e�~ʥC�f�X` מ�A�Ϝ�*q���y��+d��~����j٧�������6g������9��'�O���������8�ߟ���o�b��������~v����3����cxS��򓏎O�	QO�dM��5H8��4��q��R,+�G��������pp�Ǫ� ����Y�hr�^�u����?�{h�Sl]z!�b2��(��d`��c�\L�(��
n4'6)DB`�7��d!����� K�@]�:�4d���7�@� :fB�>=<�#n�փ���/������z��5=15�P8��5�̸^H	 �=ဓ��]�i����9�TC��沨�S,���yI]��*�#O��s���AVH�����J�=a_}��1�9��O�E��V���La2��xF=�Xtϛƥr�����,��ag�j�- 2h`��f� ��(b�B)�X7g��𣀺!W$LE\k�Vb��G�s�P����ɘ~੗0��i�J!���G
���󵃧'��X�G��9�e2���_�vA�Fa|F�OMAc]�)+�4�mCz_8��8�5#7$BHF��������!���|�q�����Y,�UW��oN����d�T8�)��SPL��(�2k�9����0�W�T��p� �����.���y](2�{Wu9����X-Z��m_zBm|ɏ��B����E����MB�mW.i�>�P1�����LY���E[��గ^�N�zc,��U������<L����$��a���$Hh8j��p~�Ro٪�P�	 �@$�=d#b�7ӷ&���i"z�?~����3��!='�sq����$�f���:)�"ɳ�|U�։�m����
뎾���Y�.|A~V�~�j���W�%�hO.|d�M<3y�1x��xa[��jtP�����&��%�� ���Y��&���y���Ty���z�D���M0wB�/z����Ӏ�]H"�6����+z=�n��L�:�"11Qܭ$�x� �Lto���N*�n&�.Q�z(~"�����o�y��(<�_15K&�0"�JHHTtOc7��4�����HLl��c��$�!1�𾵍�\��;ǭ[�f�n�
63���S\ￎ��ef%#���Zg���S����66��leS���+�Z͐��ծ�5R��?�u�R*½>��Lw���%z+Er�':���1��B�H]�@�5���{C����8��=p�Ɵ{W�<Ne�,~Y1��T�b^�wgOv!�",���2�b��V���Xc�چՋط*�4�Jlc��@����֏ϛ�Rk�����b����y�z�j����}i%I'N��f�K�a���V��Br����I��ȝc�g����?����u�L!�B!�B!�B!��[����n x  