# Every suite now lives in the test package of the component it covers:
#
#   julia --project=package/packet/test    -e 'using InetPacketTest;    test_packet()'
#   julia --project=package/queuing/test   -e 'using InetQueuingTest;   test_queuing()'
#   julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'
