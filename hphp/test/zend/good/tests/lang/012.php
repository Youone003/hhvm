<?php
function F () {
    if(1) {
        return("Hello");
    }
}
<<__EntryPoint>> function main() {
$i=0;
while ($i<2) {
    echo F();
    $i++;
}
}
