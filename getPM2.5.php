<?php
$url = 'http://monitoring.krakow.pios.gov.pl/dane-pomiarowe/pobierz';
//TODO: WTF is channels ?
$data = array('query' => '{"measType":"Auto","viewType":"Station","dateRange":"Day","date":"' . date('d.m.Y') . '","viewTypeEntityId":6,"channels":[1711,44,46,202,43,42,45]}');

$options = array(
    'http' => array(
        'header'  => "Content-type: application/x-www-form-urlencoded\r\n",
        'method'  => 'POST',
        'content' => http_build_query($data)
    )
);
$context  = stream_context_create($options);
$result = file_get_contents($url, false, $context);
if ($result === FALSE) { 
	echo 'DATA NOT AVAIABLE or SCRIPT BROKEN'; 
	exit; 
}

$dane = json_decode($result);

foreach ( $dane->data as $pdatas ) {
	if ( is_array($pdatas) ) {
		foreach ($pdatas as $pdata) {
			if ( isset($pdata->paramCode) && $pdata->paramCode == 'PM2.5' ) {
				$tmp = end($pdata->data);
				echo 'PM2.5 Concentration: ' . $tmp[1] . ' ' . $pdata->unit . ', date: ' . date('Y-m-d H:i:s',$tmp[0]) . "\n";
				exit;
			}

		}
	}
}
?>