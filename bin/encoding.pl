#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;
use Encode;
use Text::Unidecode;
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";
#binmode STDOUT, ':utf8';
binmode STDOUT, ":encoding(UTF-8)";
#use encoding 'utf8';


=example 2
#http://www.nestor.minsk.by/sr/2008/09/sr80902.html
кириллический символ А - 0xD090. Это и есть представление символа CYRILLIC CAPITAL LETTER A, закодированное при помощи UTF-8.
say "А";            # oct - flag    internal
say "\x{410}";      # char + flag   <<<хорошо
say "\x{d0}\x{90}"; # oct +flag     плохо
=cut

=utf8::*
utf8::downgrade: -flag
utf8::upgrade: +flag
utf8::downgrade("\x{d0}\x{90}") 'А'
utf8::upgrade('А') : "\x{d0}\x{90}"

utf8::encode: char > oct, -flag
utf8::decode: oct > char, +flag* (флаг выставляется только в том случае, если строка содержит символы с кодами, большими 255; см. perunicode).
utf8::encode("\x{410}") : "А"
utf8::decode("А") : "\x{410}"

utf8::is_utf8 check flag state
utf8::is_utf8("\x{410}") = 1
utf8::is_utf8("\x{d0}\x{90}") = 1
utf8::is_utf8('А') = undef
=cut

=Encode::* данные в разных кодировках
_utf8_off: -flag
_utf8_on: +flag
encode: char > oct, -flag
decode: oct > char, +flag*
is_utf8 check flag state

encode("cp1251","\x{410}") = chr(0xC0)
# Acts like FB_PERLQQ but <U+XXXX> is used instead of \x{XXXX}.
$ascii = encode("ascii", $utf8, sub{ sprintf "<U+%04X>", shift });
decode("cp1251",chr(0xC0)) = "\x{410}"
=cut

=use utf8
Директива use utf8 «выполняет» utf8::decode( <SRC> ).

binmode STDOUT, ':utf8';
use utf8;
$_ = "А";
utf8::decode($_);
print Dumper $_; # "А"
print lc; # А
print /(\w)/;
print /(а)/i;
=cut



=use encoding
use encoding 'cp1251', STDOUT => 'koi8-r';

=cut


=binmode
Проблема заключается в том, что перл не знает, поддерживается ли utf-8 данным дескриптором. Мы можем ему об этом сообщить:

binmode(STDOUT,':utf8');
binmode($log, ':encoding(cp1251)');

use open IN  => ":crlf", OUT => ":bytes";
use open OUT => ':utf8';
use open IO  => ":encoding(koi8-r)";
use open IO  => ':locale';
use open ':utf8';
use open ':encoding(utf8)'
use open ':locale';
use open ':encoding(cp1251)';
use open ':std';

=cut

=readme
http://habrahabr.ru/blogs/perl/53578/
Вариантов для работы с уникодными данными в Perl несколько. Основные из них это:
   1. принудительное указание уникодных символов в строке — через конструкцию вида \x{0100};
   2. ручная перекодировка строки при помощи модуля Encode, либо функций из пакета utf8;
   3. включение прагмы use utf8 — флаг поднимается у всех констант, которые встретились в коде;
   4. чтение из дескриптора ввода-вывода с указанием IO-Layers :encoding или :utf8 — все данные автоматически перекодируются во внутренний формат.
=cut


=var
%unicode = (
"%u0430" => «а», "%u0431" => «б», "%u0432" => «в»,
"%u0433" => «г», "%u0434" => «д», "%u0435" => «е»,
…
);
$query_value =~ s/(%u[0-9A-F]{4})/$unicode{$1}/eg;
=cut


#encodings
#use Encode qw/resolve_alias/;
#Encode->encodings(":all");
#my $enc = shift;
#usage() unless $enc;
#my $canon = resolve_alias( $enc );
#unless( $canon ) {
#        print "Encoding '$enc' is not supported\n";
#        exit 1;
#}


################################################################################
#########   Unicode part
################################################################################

# конвертирование HTML entities.
#my $str = "&#x0442;&#x0435;&#1089;&#1090;";
#$str =~ s/&#x([a-fA-F0-9]+);/"&#". hex($1) .";"/ge;
#say $str;
#$str =~ s/&#([0-9]+);/chr($1)/ge;
#print "$str\n";

#use charnames ':full';
#print "\N{LATIN CAPITAL LETTER A}\N{COMBINING ACUTE ACCENT}", "\n";
#say "\N{ARABIC LETTER ALEF}";
#print length("\N{LATIN CAPITAL LETTER A}\N{COMBINING ACUTE ACCENT}"), "\n";


require "YAML.pl";
use Unicode::UCD qw{charinfo charblock charscript charblocks charscripts};
#my $charinfo = charinfo(0x41);
#say Dumper $charinfo;
#say Dumper charblock('Cyrillic');
#say Dumper charscript('Cyrillic');
#say Dumper charblocks();
#yaml_print(charblocks());
yaml_print(charscripts());


sub filter_koi {
    local $_ = Encode::decode('koi8-r', shift);     # передем koi8-r в строку
    s{&#(\d+);}{chr($1)}ge; # заменим все html-entity соответствующими символами юникода

    s{(?:\p{WhiteSpace}|\p{Z})}{ }g; # проведем некоторые замены пробельные символы пробелом

    s{\p{QuotationMark}}{"}g;   # все кавычки – двойными

    s{\p{Dash}}{-}g;    # минусы, дефисы, тире и т.п. - дефисами

    s{\p{Hyphen}}{-}g;  # символ переноса тоже дефисом

    s{\x{2026}}{...}g;  # символ троеточия тремя точками

    s{\x{2116}}{N}g;    # символ номера заменяем на N

    return Encode::encode('koi8-r',$_); # Вернем строку обратно в кодировке koi8-r
}