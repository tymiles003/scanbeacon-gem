module ScanBeacon
  class BLE112Device

    # define a bunch of constants
    BG_COMMAND = 0
    BG_EVENT = 0x80
    # msg classes
    BG_MSG_CLASS_SYSTEM = 0
    BG_MSG_CLASS_CONNECTION = 3
    BG_MSG_CLASS_GAP = 6
    # messages
    BG_RESET = 0
    BG_DISCONNECT = 0
    BG_SET_MODE = 1
    BG_GET_ADDRESS = 2
    BG_GAP_SET_PRIVACY_FLAGS = 0
    BG_GAP_SET_ADV_PARAM = 8
    BG_GAP_SET_ADV_DATA = 9

    BG_DISCOVER = 2
    BG_DISCOVER_STOP = 4
    BG_SCAN_PARAMS = 7
    # constants/enums
    BG_GAP_DISCOVER_ALL = 2
    BG_GAP_NON_DISCOVERABLE = 0
    BG_GAP_NON_CONNECTABLE = 0
    BG_GAP_USER_DATA = 4
    BG_GAP_CONNECTABLE = 2

    def self.find_all
      devices = Dir.glob("/dev/{cu.usbmodem,ttyACM}*")
      devices.select {|device_path|
        device = self.new(device_path)
        device.open{ device.get_addr } != nil
      }
    end

    def initialize(port=nil)
      @port = port || BLE112Device.find_all.first
    end

    def open
      response = nil
      configure_port
      File.open(@port, 'r+b') do |file|
        @file = file
        response = yield(self)
      end
      @file = nil
      return response
    end

    def configure_port
      if RUBY_PLATFORM =~ /linux/
        system("stty -F #{@port} 115200 raw -brkint -icrnl -imaxbel -opost -isig -icanon -iexten -echo -echoe -echok -echoctl -echoke")
      end
    end

    def get_addr
      response = bg_command(@file, BG_MSG_CLASS_SYSTEM, BG_GET_ADDRESS)
      response[4..-1].reverse.unpack("H2:H2:H2:H2:H2:H2").join(":") if response.length == 10
    end

    def start_scan
      # disconnect any connections
      bg_command(@file, BG_MSG_CLASS_CONNECTION, BG_DISCONNECT,0)
      # turn off adverts
      bg_command(@file, BG_MSG_CLASS_GAP, BG_SET_MODE, [BG_GAP_NON_DISCOVERABLE, BG_GAP_NON_CONNECTABLE])
      # stop previous scan
      bg_command(@file, BG_MSG_CLASS_GAP, BG_DISCOVER_STOP)
      # write new scan params
      bg_command(@file, BG_MSG_CLASS_GAP, BG_SCAN_PARAMS, [200,200, 0], "S<S<C")
      # start new scan
      bg_command(@file, BG_MSG_CLASS_GAP, BG_DISCOVER, BG_GAP_DISCOVER_ALL)
    end

    def stop_scan
      bg_command(@file, BG_MSG_CLASS_GAP, BG_DISCOVER_STOP)
    end

    def start_advertising(ad_data, privacy = false)
      # disconnect any connections
      bg_command(@file, BG_MSG_CLASS_CONNECTION, BG_DISCONNECT,0)

      # set advertising interval 0x00A0 = 100 ms interval, 7 = all channels
      bg_command(@file, BG_MSG_CLASS_GAP, BG_GAP_SET_ADV_PARAM, [0xA0, 0x00, 0xA0, 0x00, 7])

      # set privacy mode (rotate bluetooth address)
      if privacy
        bg_command(@file, BG_MSG_CLASS_GAP, BG_GAP_SET_PRIVACY_FLAGS, [1, 0])
      end

      # add flags header
      ad_data = "\x02\x01\x06" + ad_data
      ad_data = [0,ad_data.size].pack("C*") + ad_data

      stop_advertising
      bg_command(@file, BG_MSG_CLASS_GAP, BG_GAP_SET_ADV_DATA, ad_data.unpack("C*"))
      bg_command(@file, BG_MSG_CLASS_GAP, BG_SET_MODE, [BG_GAP_USER_DATA, BG_GAP_CONNECTABLE])
    end

    def rotate_addr
      # set peripheral into private mode is not needed, as the mac is rotated every time gap_set_mode is called
      bg_command(@file, BG_MSG_CLASS_GAP, BG_GAP_SET_PRIVACY_FLAGS, [1, 0])

      # set gap mode
      bg_command(@file, BG_MSG_CLASS_GAP, BG_SET_MODE, [BG_GAP_USER_DATA, BG_GAP_CONNECTABLE])
    end

    def stop_advertising
      bg_command(@file, BG_MSG_CLASS_GAP, BG_SET_MODE, [BG_GAP_NON_DISCOVERABLE, BG_GAP_NON_CONNECTABLE])
    end

    def read
      BLE112Response.new( bg_read(@file) )
    end

    def reset
      open do
        @file.write([BG_COMMAND, 1, BG_MSG_CLASS_SYSTEM, BG_RESET, 0].pack('C*'))
      end
      # give time for the device to reboot.
      # TODO: figure out a way that doesn't involve sleeping arbitrarily.
      sleep 1
    end

    class BLE112Response
      def initialize(data)
        @data = data.force_encoding("ASCII-8BIT")
      end

      def size
        @data.size
      end

      def event?
        @data[0].unpack('C')[0] == BG_EVENT
      end

      def gap_scan?
        @data[2..3].unpack('CC') == [BG_MSG_CLASS_GAP, 0]
      end

      def manufacturer_ad?
        size > 20 && advertisement_type == 0xFF
      end

      def service_ad?
        size > 20 && advertisement_type ==0x03
      end

      def advertisement?
        event? && gap_scan? && (manufacturer_ad? || service_ad?)
      end

      def advertisement_type
        @data[19].unpack('C')[0]
      end

      def advertisement_data
        @advertisement_data ||= @data[20..-1]
      end

      def mac
        @data[6..11].unpack('H2 H2 H2 H2 H2 H2').join(":")
      end

      def rssi
        @data[4].unpack('c')[0]
      end
    end

    private

      def bg_command(port, msg_class, msg, data=nil, data_format=nil)
        data = [data].compact unless data.is_a? Array
        if data_format.nil?
          data = data.pack('C*')
        else
          data = data.pack(data_format)
        end
        cmd = [0, data.size, msg_class, msg].flatten.pack('C*') + data
        port.write(cmd)
        bg_read(port)
      end

      def bg_read(port)
        response = port.read(1) while response.nil? || ![0x00, 0x80].include?(response.unpack('C')[0])
        response << port.read(3)
        payload_length = response[1].unpack('C')[0]
        response << port.read(payload_length)
      end
  end
end
