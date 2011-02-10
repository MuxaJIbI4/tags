#!/usr/bin/perl -w
package Lingua::DetectCyrillic;
use strict;
no strict 'vars';
use warnings;
use feature ":5.10";
use encoding 'utf8';
use Encode;

#tmp
use Data::Dumper;


use vars qw( @ISA @EXPORT @EXPORT_OK );
require Exporter;
our @ISA = qw( Exporter );
our $VERSION = "0.02";

use lib "$ENV{HOME}/workspace/tags/";;

# Увеличение словаря с 300 до 3000 слов практически ничего не дало:
# при распознавании koi8/windows разница была порядка 30.
# Активизируем словари и хэши
our ($DictRusSum , %DictRus, %DictUkr);
our (%WordHash2Rus, %WordHash2Ukr);
require 'Lingua/DetectCyrillic/DictRus.pl';
require 'Lingua/DetectCyrillic/DictUkr.pl';
require 'Lingua/DetectCyrillic/WordHash2Rus.pl';
require 'Lingua/DetectCyrillic/WordHash2Ukr.pl';
#print decode_utf8($_)." "  foreach keys %DictRus;say "";
#print $_." "  foreach keys %DictRus;say "";

# Глобальные переменные
my $FullStat;
my (%Args, @Codings);
my (@InputData, %Stat);
my ($Language, $Coding, $Algorithm, $MaxCharsProcessed);


### Экспортируемые переменные
my %RusCharset;
$RusCharset{'Upper'}        = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯҐЄІЇЎ";
$RusCharset{'Lower'}        = "абвгдеёжзийклмнопрстуфхцчшщъыьэюяґєіїў";
$RusCharset{'Ukrainian'}    = "ҐґЄєІіЇї";
$RusCharset{'Punctuation'}  = "«»“”–—№";
$RusCharset{'All'}          = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ".
                                  "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".
                                  "ҐґЄєІіЇї".
                                  "Ўў«»“”–—№";
### Конец экспортируемых переменных

sub new {

    # Заполнили данные по умолчанию

    my $self = {};
    my $class = shift;

    # Зачитали аргументы - это глобальный хэш
    (%Args) = @_;

    @Codings = ( "cp1251", "cp1252", "koi8-r", "cp866", "utf-8");
#    @Codings = ( "win1251", "cp1252", "koi8r", "cp866", "utf8");
#    @Codings = ( "cp1251" , "utf-8" );
#    @Codings = ( "cp1251");
    if ( exists $Args{DetectAllLang} ) {
        push @Codings, 'koi8-u';
    }
    else {
        $Args{DetectAllLang} = 0 ;
    }
    $Args{MaxTokens} = 100 unless exists $Args{MaxTokens};

    @InputData = "";

    return bless($self, $class);
}



sub LogWrite {
    shift;
    my $Outfile = shift;
    my $OUT;
# Выводим отчет. Если названия файла нет, или это stdout - выводим на экран, иначе в файл

    if ( !$Outfile or uc($Outfile) eq "STDOUT" ) {
        $OUT = \*STDOUT;
    } else {
        open $OUT, ">$Outfile";
    }

    select $OUT;
    $~ = "STAT";
    print
      "Coding: $Coding    Language: $Language     Algorithm: $Algorithm \n\n";
    print
"         GdChr  GdCnt AllChr AllCnt ChrUkr    HashRus   HashUkr  WRus  WUkr\n";
    print "*" x 78 . "\n";
    ########### Формат отчета ##########
    foreach  my $key ( keys %Stat ) {
    format STAT =
@<<<<<<@######@######@######@######@######@##########@##########@######@######
$key,$Stat{$key}{GoodTokensChars},$Stat{$key}{GoodTokensCount},$Stat{$key}{AllTokensChars},$Stat{$key}{AllTokensCount},$Stat{$key}{CharsUkr},$Stat{$key}{HashScore2Rus},$Stat{$key}{HashScore2Ukr},$Stat{$key}{WordsRus},$Stat{$key}{WordsUkr}
.
        write;
    }
    print "*" x 78 . "\n";
    print "Time: " . localtime() . "\n";
    print <<POD;
 GoodTokensChars - number of characters in pure Cyrillic tokens with correct
capitalization.
 GoodTokensCount - number of pure Cyrillic tokens with correct capitalization.
 AllTokensChars - number of characters in tokens containing Cyrillica.
 AllTokensCount - their number
 CharsUkr - number of Ukrainian letters
 HashScore2Rus (Ukr) - hits on 2-letter hash
 WordsRus (Ukr) - hits on frequency dictionary
POD

    select STDOUT;
    if ( $OUT ne \*STDOUT ) { close $OUT; }

}    # LogWrite()

sub Detect {
    my $class = shift;

    $FullStat = 0;
    #(%Stat);

# Перегружаем в глобальный массив @InputData, он может понадобиться еще раз
# при получении расширенной статистики.
    (@InputData) = @_;

    _GetStat();

    # Теперь выясняем кодировку
    $Language  = "";
    $Coding    = "";
    $Algorithm = 0;
      ; # Это примененная схема определения кодировки
    $MaxCharsProcessed = 0;
    _AnalyzeStat();
    $Coding = "iso-8859-5"      if $Coding eq "iso";
    $Coding = "x-mac-cyrillic"  if $Coding eq "mac";
    $Coding = "iso-8859-1"      if $Coding eq "";

    return ( $Coding, $Language, $MaxCharsProcessed, $Algorithm );

}

sub _GetStat {

# Инициализируем структуру хэшей (описание см. в конце)

    for (@Codings) {
        if ($FullStat) {
#            $Stat{$_}{GoodTokensChars} = 0;
#            $Stat{$_}{GoodTokensCount} = 0;
            $Stat{$_}{AllTokensChars} = 0;
            $Stat{$_}{AllTokensCount} = 0;
            $Stat{$_}{CharsUkr}       = 0;
            $Stat{$_}{HashScore2Rus}  = 0;
            $Stat{$_}{HashScore2Ukr}  = 0;
            $Stat{$_}{WordsRus}       = 0;
            $Stat{$_}{WordsUkr}       = 0;

        } else {    # $FullStat

            $Stat{$_}{GoodTokensChars} = 0;
            $Stat{$_}{GoodTokensCount} = 0;
            $Stat{$_}{CharsUkr}        = 0;
#            $Stat{$_}{AllTokensChars} = 0; #
#            $Stat{$_}{AllTokensCount} = 0; #
#            $Stat{$_}{HashScore2Rus}  = 0; #
#            $Stat{$_}{HashScore2Ukr}  = 0; #
#            $Stat{$_}{WordsRus}       = 0; #
#            $Stat{$_}{WordsUkr}       = 0; #

        }    # $FullStat
    }    # end for

    # Получаем статистику для каждой строки
    my $EnoughTokens = 0;
    foreach (@InputData) {
        my $String = $_;

        foreach (@Codings) {
            _ParseString( $_, $String, $Stat{$_} );
# Выходим, если хоть по одной из кодировок набрали максимальное число токенов
#            say "Found good tokens: $Stat{$_}{GoodTokensCount}";
#            say Dumper( $Stat{$_});
            if ( $Stat{$_}{GoodTokensCount} > $Args{MaxTokens} ) {
                $EnoughTokens = 1;
            }
        }

        if ($EnoughTokens) { last; }
    }    # Конец получения статистики

}

sub _AnalyzeStat {

# Сначала анализируем соотношение букв в чисто кириллических токенах
# с правильной капитализацией

## Анализируем формальную статистику по токенам с кириллицей
# Минимальное соотношение токенов с правильной капитализацией, при котором
# разницу считаем значимой для вычисления результата. Пока не используется.
# my $TokensRatio=0.95;
# Минимальный процент токенов с украинскими символами, чтобы текст считался украинским
    my $UkrTokensShare = 0.01;

## Анализируем чисто кириллические токены с правильной капитализацией.
    my @CyrCharRating;
    for (@Codings) {
        push @CyrCharRating, [ $_, $Stat{$_}{GoodTokensChars} ];
    }
    @CyrCharRating = sort { $b->[1] <=> $a->[1] } @CyrCharRating;

    $MaxCharsProcessed = $CyrCharRating[0]->[1];
#    say "MaxCharsProcessed=$MaxCharsProcessed";

# После сортировки получаем список наиболее вероятных кодировок
# Они содержат максимальное число "правильных" кириллических слов в данной кодировке
# Выясняем, между сколькими кодировками нужно провести различие
    my @BestCodings;
    for my $arrayref (@CyrCharRating) {
        if ( $arrayref->[1] == $CyrCharRating[0]->[1] ) {
            push @BestCodings, $arrayref->[0];
        }
    }

# Если первая возможная кодировка содержит больше правильных символов,
# чем любая иная, считаем, что дело сделано. Вообще здесь лучше ввести
# определение минимально необходимого преимущества, скажем, 10% или что-то вроде.

    if ( scalar(@BestCodings) == 1 ) {
        $Coding = $CyrCharRating[0]->[0];
#        say "Best Coding is $Coding";
        return if $Stat{$Coding}{GoodTokensCount} == 0;
# Определяем язык. Смотрим, нет ли украинских токенов. Если они присутствуют
# в количестве не менее $UkrTokensShare, считаем язык украинским, иначе - русским.
        if ( $Stat{$Coding}{CharsUkr} / $Stat{$Coding}{GoodTokensCount} >
             $UkrTokensShare )
        {
            $Language = "Ukr";
        } else {
            $Language = "Rus";
        }
        $Algorithm = 11;
        return;
    }    # Конец разбора одной кодировки

# Следующий вариант: одинаковое число баллов набрали ровно две кодировки.
# Не исключено, что это либо koi русский и украинский, либо win1251 и мас.
# Тогда мы их можем различить по формальным параметрам.
    if ( scalar(@BestCodings) == 2 ) {

        my $BestCoding1 = $CyrCharRating[0]->[0];
        my $BestCoding2 = $CyrCharRating[1]->[0];

       # Первый вариант - это кодировки koi8u и koi8r.
        if ( $BestCoding1 =~ /koi/ && $BestCoding2 =~ /koi/ ) {

# Определяем язык и на этом основании - кодировку
            if (    $Stat{$Coding}{GoodTokensCount} > 0
                 && $Stat{$Coding}{CharsUkr} /
                 $Stat{$Coding}{GoodTokensCount} > $UkrTokensShare )
            {
                $Coding   = "koi8-u";
                $Language = "Ukr";
            } else {
                $Coding   = "koi8-r";
                $Language = "Rus";
            }
            $Algorithm = 21;
            return;
        }    # Конец 1-го варианта

# Второй вариант - это кодировки win1251 и mac. То есть весь текст записан
# строчными буквами без Ю и Э. Предпочитаем однозначно win1251
        if (    $BestCoding1 =~ /(cp1251|mac)/
             && $BestCoding2 =~ /(cp1251|mac)/ )
        {
            $Coding = "cp1251";
            if (    $Stat{$Coding}{GoodTokensCount} > 0
                 && $Stat{$Coding}{CharsUkr} /
                 $Stat{$Coding}{GoodTokensCount} > $UkrTokensShare )
            {
                $Language = "Ukr";
            } else {
                $Language = "Rus";
            }
            $Algorithm = 22;
            return;
        }    # Конец 2-го варианта

    } # Конец разбора двух кодировок при котором когда мы еще можем обойтись только анализом

# "правильных" символов,  без привлечения расширенной статистики

# Итак, кодировку с ходу не удалось определить по статистике символов с правильной
# капитализацией. Тогда устанавливаем флаг $FullStat и еще раз получаем статистику по
# строкам - на этот раз с хэшем и словарем
    $FullStat = 1;
    _GetStat();

# Проверяем, а есть ли кириллица в тексте вообще.
    for (@BestCodings) {
        push @CyrCharRating, [ $_, $Stat{$_}{AllTokensChars} ];
    }
    @CyrCharRating = sort { $b->[1] <=> $a->[1] } @CyrCharRating;

    $MaxCharsProcessed = $CyrCharRating[0]->[1];

# Выйти, если не было ни одного кириллического символа
    if ( $MaxCharsProcessed == 0 ) {
        $Coding    = "iso-8859-1";
        $Language  = "NoLang";
        $Algorithm = 100;
        return;
    }

# Делаем следующие два шага. Сначала создаем массив из комбинаций языка и кодировки
# для подсчета слов из словаря, затем оставляем только комбинации с максимальным значением,
# т.е. сужаем список потенциальных комбинаций. Если этих комбинаций больше одной,
# переходим ко второму шагу - создаем аналогичный массив для хэшей и снова отбираем
# комбинации с максимальным значением. Если снова не удалось выделить единственного
# "победителя", предпочитаем русский язык украинскому, кодировку windows - макинтошу.

# Шаг 1. Ищем максимальный рейтинг слов из частотного словаря
    my @WordsRating;
    for (@BestCodings) {
        push @WordsRating, [ $_, "Rus", $Stat{$_}{WordsRus} ];
        push @WordsRating, [ $_, "Ukr", $Stat{$_}{WordsUkr} ];
    }
    @WordsRating = sort { $b->[2] <=> $a->[2] } @WordsRating;

#print "WordsRating: \n";
#for my $arrayref (@WordsRating) {
#  print "  " . $arrayref ->[0] . " " .$arrayref ->[1] ." ".$arrayref ->[2] ."\n"; }

# Если обнаружили в тексте хотя бы одно слово из словаря, и нет альтернатив,
# то считаем, что определение языка/кодировки произошло
    if (    $WordsRating[0]->[2] > 0
         && $WordsRating[0]->[2] > $WordsRating[1]->[2] )
    {
        $Coding    = $WordsRating[0]->[0];
        $Language  = $WordsRating[0]->[1];
        $Algorithm = 31;
        return;
    }

# Либо слова из частотного словаря вообще не были обнаружены,
# либо имеем совпадение числа слов для нескольких комбинаций язык/кодировка
#  Шаг 2. Обращаемся к хэшу и еще больше сужаем ареал поиска.

    my @BestWordsRating;
    for my $arrayref (@WordsRating) {
        if ( $arrayref->[2] == $WordsRating[0]->[2] ) {
            push @BestWordsRating,
              [ $arrayref->[0], $arrayref->[1], $arrayref->[2] ];
        }
    }

#print "BestWordsRating: \n";
#for $arrayref (@BestWordsRating) {
#  print "  " . $arrayref ->[0] . " " .$arrayref ->[1] ." ".$arrayref ->[2] ."\n"; }

    my @HashRating;
    for my $arrayref (@BestWordsRating) {

        if ( $arrayref->[1] eq "Rus" ) {
            push @HashRating,
              [
                $arrayref->[0], "Rus",
                $Stat{ $arrayref->[0] }{HashScore2Rus}
              ];
        }
        if ( $arrayref->[1] eq "Ukr" ) {
            push @HashRating,
              [
                $arrayref->[0], "Ukr",
                $Stat{ $arrayref->[0] }{HashScore2Ukr}
              ];
        }

    }
    @HashRating = sort { $b->[2] <=> $a->[2] } @HashRating;

#for $arrayref (@HashRating) {
#  print "  " .$arrayref ->[0] . " " .$arrayref ->[1] ." ".$arrayref ->[2] ."\n"; }

# Если обнаружили в тексте хотя бы один реальный хэш, и нет альтернатив,
# то считаем, что определение языка/кодировки произошло
    if ( $HashRating[0]->[2] > 0 && $HashRating[0]->[2] > $HashRating[1]->[2] )
    {
        $Coding    = $HashRating[0]->[0];
        $Language  = $HashRating[0]->[1];
        $Algorithm = 32;
        return;
    }

# Либо хэш не обнаружен, либо имеем совпадение числа слов для нескольких комбинаций
# язык/кодировка
# Шаг 3. Оставляем только те комбинации язык/кодировка, которые содержат наибольшее число
# попаданий в хэш.

    my @BestHashRating;
    for my $arrayref (@HashRating) {
        if ( $arrayref->[2] == $HashRating[0]->[2] ) {
            push @BestHashRating, [ $arrayref->[0], $arrayref->[1] ];
        }
    }

# for $arrayref (@BestHashRating) {
#  print "  " .$arrayref ->[0] . " " .$arrayref ->[1] ." ".$arrayref ->[2] ."\n"; }

# Теперь наступили тяжелые времена. ;-)) Остались только те комбинации кодировка/язык,
# для которых полностью совпадают данные и по частотному словарю, и по хэшу.
# Это может случиться ровно в двух случаях. Первый - весь текст набран строчными буквами.
# Тогда смешиваются Mac/Win. Предпочитаем Win.
# Второй - текст в koi набран без украинских букв. Тогда смешиваются koi8-r и koi8-u.
# Предпочитаем koi8-r (впрочем, разницы в данном случае никакой).

    for my $arrayref (@BestHashRating) {
        if ( $arrayref->[0] =~ /win/ ) {
            $Coding = "cp1251";
            if (    $Stat{$Coding}{GoodTokensCount} > 0
                 && $Stat{$Coding}{CharsUkr} /
                 $Stat{$Coding}{GoodTokensCount} > $UkrTokensShare )
            {
                $Language = "Ukr";
            } else {
                $Language = "Rus";
            }
            $Algorithm = 33;
            return;
        }
    }

    for my $arrayref (@BestHashRating) {
        if ( $arrayref->[0] =~ /koi/ ) {
            $Coding    = "koi8r";
            $Language  = "Rus";
            $Algorithm = 34;
            return;
        }
    }

# Ничего не подошло. Устанавливаем первую победившую кодировку и язык.
    $Coding    = $BestHashRating[0]->[0];
    $Language  = $BestHashRating[0]->[1];
    $Algorithm = 40;

    return;
}    #end _AnalyzeStat()

sub _ParseString {
    my ( $Coding, $String, $hash_ref ) = @_;
#    $hash_ref->{test} = "adasdasdadassd";say Dumper(%Stat);
#    print ord($_)." " foreach split '', $String;say "";
#    print ord($_)." " foreach split '', $RusCharset{'Lower'};say "";
#    print ord($_)." " foreach split '', $RusCharset{'Upper'};say "";
# Перевели строку в кодировку win1251 и убрали знаки новой строки
    my $tmp;
    my $enc_out = 'cp1251';
#    my $enc_out = 'utf-8';
    if ($Coding =~ /(1251|win)/i) {
        $tmp = decode($enc_out, encode('cp1251', $String));
#        $tmp = encode('cp1251', $String);
    }
    if ($Coding =~ /(1252)/i) {
        $tmp = decode($enc_out, encode('cp1252', $String));
#        $tmp = $tmp = encode('cp1252', $String);
    }
    if ($Coding =~ /(koi8-r)/i) {
        $tmp = decode($enc_out, encode('koi8r', $String));
#        $tmp = $tmp = encode('koi8-r', $String);
    }
    if ($Coding =~ /(utf|uni)/i) {
        $tmp = decode($enc_out, encode('utf-8', $String));
#        $tmp = $tmp = encode('utf-8', $String);
    }
    if ($Coding =~ /(dos|866|alt)/i) {
        $tmp = decode($enc_out, encode('cp866', $String));
#        $tmp = $tmp = encode('cp866', $String);
    }
    if ($Coding =~ /(iso|8859-5)/i) {
        $tmp = decode($enc_out, encode('ISO_8859-5', $String));
#        $tmp = $tmp = encode('ISO_8859-5', $String);
    }
#    if ($tmp eq $String) {
#        # HACK ?????
#        say ">>> Equal";
#        $Coding = $enc_out;
#    }
    $String = $tmp;
    $String =~ s/[\n\r]//go;
#    say "\n$Coding:\n\t$String";
    ## Разбитие на слова
    ## \xAB\xBB - полиграфические кавычки, \x93\x94 - кавычки-"лапки",
    ## \xB9 - знак номера, \x96\x97 - полиграфические тире
    foreach ( split(
                 /[\xAB\xBB\x93\x94\xB9\x96\x97\.\,\-\s\:\;\?\!\"\(\)\d<>]+/o,
                 $String
                    ) ) {
        my $tok = $_;
        $tok =~ s/^\'+(.*)\'+$/$1/; # Убрали начальные и конечные апострофы
#        say "$tok <<";
        if ($Coding =~ /1251/) {
#            print ord($_)." " foreach split '', $tok ;say "";
        }
        if ( !$FullStat ) {
#            say "lower"
#                if $tok =~ /^[$RusCharset{'Lower'}]+$/;
#            say "lower+upper"
#                if $tok =~ /^[$RusCharset{'Upper'}]{1}[$RusCharset{'Lower'}]+$/;
#            say "upper"
#                if $tok =~ /^[$RusCharset{'Upper'}]+$/;
#            my $upper = qr/[$RusCharset{'Upper'}]/;
#            my $lower = qr/[$RusCharset{'Lower'}]/;
            # Определяем, "правильный" ли это токен, т.е. содержит только кириллицу
            # и либо строчные буквы, либо ПРОПИСНЫЕ, либо начинается с Прописной.
#            if (  $tok =~ /^$lower+$/
#               || $tok =~ /^$upper{1}$lower+$/
#               || $tok =~ /^$upper+$/ )
            1;
            if (  $tok =~ /^[$RusCharset{'Lower'}]+$/
               || $tok =~ /^[$RusCharset{'Upper'}]{1}[$RusCharset{'Lower'}]+$/
               || $tok =~ /^[$RusCharset{'Upper'}]+$/ )
            {
#                say "GoodTokensChars: $tok";
                $hash_ref->{GoodTokensChars} += length();

                # Для UTF умножаем число кириллических символов на два.
                if ( $Coding eq "utf" ) {
                    $hash_ref->{GoodTokensChars} += length();
                }
                $hash_ref->{GoodTokensCount}++;

                # Если токен содержит украинские символы, увеличить счетчик украинских токенов
                if ( $Args{DetectAllLang} && /[$RusCharset{'Ukrainian'}]/ ) {
                    $hash_ref->{CharsUkr}++;
                }
            }

        } else {    # !$FullStat

# Определяем, можно ли вообще проводить над этим токеном какие-либо действия.
# Для этого он должен содержать хотя бы одну правильную кириллическую букву,
# английские буквы и цифры в любой смеси.
            if ( /[$RusCharset{'All'}]/ && /^[\w\d$RusCharset{'All'}]+$/ ) {
                $hash_ref->{AllTokensChars} += length();

          # Для UTF умножаем число символов на два.
                if ( $Coding eq "utf" ) { $hash_ref->{AllTokensChars} += length(); }

# Если токен содержит украинские символы, увеличить счетчик украинских токенов
                if ( $Args{DetectAllLang} && /[$RusCharset{'Ukrainian'}]/ ) {
                    $hash_ref->{CharsUkr}++;
                }

# Теперь приступаем к обработке хэша и словарей
# Переводим токен в нижний регистр - и словарь, и хэши у нас в нижнем регистре
                $_ = lc($_);
#                $_ = toLowerCyr($_);
                if ( $DictRus{$_} ) {
                    $hash_ref->{WordsRus}++;
                }
                if ( $Args{DetectAllLang} && $DictUkr{$_} ) {
                    $hash_ref->{WordsUkr}++;
                }

                for my $i ( 0 .. length() - 1 ) {
                    if ( $WordHash2Rus{ substr( $_, $i, 2 ) } ) {
                        $hash_ref->{HashScore2Rus}++;
                    }
                    if (    $Args{DetectAllLang}
                         && $WordHash2Ukr{ substr( $_, $i, 2 ) } )
                    {
                        $hash_ref->{HashScore2Ukr}++;
                    }
                }    # end for

            }    # end  if (/^[\w\d$RusCharset{'All'}]+$/)

        }    # !$FullStat

    }    # end    for (split...

}    # end routine

1;
