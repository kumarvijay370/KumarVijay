#######################################################################################################################
# This Script has been created to Share Physical RDM's between 2 or More Virtual Machines in Multiwriter mode. The script has been created with below assumptions
# 1. List of Virtual Machines provided are part of a cluster and have the same number of disks, whether physical or virtual, attached.
# 2. Virtual Machines provided during the script execution will be manually powered off, if the VM's are not powered off the script will not execute and will exit with error.
# 3. Shared disks will always be attached on the lates SCSI controller with the highest Bus Number even if other controllers have free ports availalbe, this is done 
# to ensure that ports left unallocated intentionally will not be consumed by mistake.
#######################################################################################################################
param(
        $PrimaryVirtualMachineName,
        $SecondaryVirtualMachinesName = @(),
        $PathtoRDMfile
    )

function GetVMCustomObject {
    param (
        $VirtualMachine,
        $RDMS
    )   
    $ESXCLI = $VirtualMachine | get-vmhost | Get-EsxCli -V2
    $devobject = @()
    foreach($RDM in $RDMS)
    {
        
        $RDM = 'naa.'+$RDM
        $Parameters = $ESXCLI.storage.core.device.list.CreateArgs()
        $Parameters.device = $RDM.ToLower()
        try{
        $naa=$ESXCLI.storage.core.device.list.Invoke($Parameters) 
        write-host found device $naa.device
        $device = New-Object psobject
        $device | add-member -MemberType NoteProperty -name "NAAID" -Value $naa.Device
        $device | add-member -MemberType NoteProperty -name "SizeMB" -Value $naa.Size
        $device | add-member -MemberType NoteProperty -name "DeviceName" -Value $naa.devfspath
        $device | Add-Member -MemberType NoteProperty -name "BusNumber" -Value $null
        $device | add-member -MemberType NoteProperty -name "UnitNumber" -value $null
        #$device | Add-Member -MemberType NoteProperty -Name "Device Key" -Value $null
        $device | add-member -MemberType NoteProperty -name "FileName" -Value $null
        $devobject += $device

    }
    catch
    {
        Write-host $RDM does not exist on host (get-vmhost -vm $VirtualMachine)
        Read-Host "Press any key to exit the Script."
        Exit
    }
}
return $devobject
}

function CreateScSiController {
    param (
        [int]$BusNumber,
        $VirtualMachine
    )
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.DeviceChange = @()
$spec.DeviceChange += New-Object VMware.Vim.VirtualDeviceConfigSpec
$spec.DeviceChange[0].Device = New-Object VMware.Vim.ParaVirtualSCSIController
$spec.DeviceChange[0].Device.SharedBus = 'physicalSharing'
$spec.DeviceChange[0].Device.ScsiCtlrUnitNumber = 7
$spec.DeviceChange[0].Device.DeviceInfo = New-Object VMware.Vim.Description
$spec.DeviceChange[0].Device.DeviceInfo.Summary = 'New SCSI controller'
$spec.DeviceChange[0].Device.DeviceInfo.Label = 'New SCSI controller'
$spec.DeviceChange[0].Device.Key = -106
$spec.DeviceChange[0].Device.BusNumber = $BusNumber
$spec.DeviceChange[0].Operation = 'add'
$VirtualMachine.ExtensionData.ReconfigVM($spec)
}

function SCSiFreePorts {
    param (
        #Required ports is RDMS.count
        $RequiredPorts,
        $PrimaryVirtualMachine,
        $SecondaryVirtualMachines
    )
    
    $ControllertoUse = @()
    $FreePorts = 0;
    $AvailablePorts = @()
    while ($FreePorts -lt $RequiredPorts) {
        $ControllerNumber = @()
        $Controllers = Get-ScsiController -vm $PrimaryVirtualMachine |  ? {$_.BusSharingMode -eq 'Physical' -and $_.Type -eq 'paravirtual'}
        $LatestControllerNumber = $null
        if ($Controllers) {
            foreach ($Controller in $Controllers) {
                $ControllerNumber += $Controller.ExtensionData.BusNumber 
            }
            $LatestControllerNumber = ($ControllerNumber | measure -Maximum).Maximum
            $RecentController = $Controllers | ? {$_.ExtensionData.BusNumber -eq $LatestControllerNumber}
            $FreePorts += 15 - $RecentController.ExtensionData.Device.count
            $ControllertoUse += $RecentController
        }
        if (($FreePorts -lt $RequiredPorts) -and ($LatestControllerNumber -eq 3)) {
            Write-Host "SCSI controller Limit has been exhausted and can not accomodate all RDM's. Exiting the Script."
            Exit
        }
        if (($FreePorts -lt $RequiredPorts) -or !$Controllers) {
            CreateScSiController -BusNumber ($LatestControllerNumber+1) -VirtualMachine $PrimaryVirtualMachine
            foreach($Virtualmachine in $SecondaryVirtualMachines)
            {
                CreateScSiController -BusNumber ($LatestControllerNumber+1) -VirtualMachine $Virtualmachine
            }
        }
    }
    foreach ($CurrentController in $ControllertoUse) {
        $ConnectedDevices = $CurrentController.ExtensionData.Device
        $UsedPort = @()
        foreach ($Device in $ConnectedDevices) {
            $DevObj = $PrimaryVirtualMachine.ExtensionData.Config.Hardware.Device | ? {$_.Key -eq $Device}
            $UsedPort += $DevObj.UnitNumber
        }
        for ($i = 0; $i -le 15; $i++) {
            if (($i -ne 7) -and ($UsedPort -notcontains $i)) {
                $PortInfo = New-Object -TypeName PSObject
                $PortInfo | Add-Member -MemberType NoteProperty -name "BusNumber" -Value $CurrentController.ExtensionData.BusNumber
                $PortInfo | add-member -MemberType NoteProperty -name "PortNumber" -value $i
                $AvailablePorts += $PortInfo
            }
        }
    }
    return $AvailablePorts
}

function AddRDM {
    param (
        $VirtualMachine,
        [String]$DeviceName,
        [Int]$ControllerKey,
        [Int]$UnitNumber,
        [Int]$Size
    )
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.DeviceChange = @()
$spec.DeviceChange += New-Object VMware.Vim.VirtualDeviceConfigSpec
$spec.DeviceChange[0].FileOperation = 'create'
$spec.DeviceChange[0].Device = New-Object VMware.Vim.VirtualDisk
# $SIZE is available in objects returned by GetVMCustomObject, size will be in MB 
$spec.DeviceChange[0].Device.CapacityInBytes = $Size*1204*1024
$spec.DeviceChange[0].Device.StorageIOAllocation = New-Object VMware.Vim.StorageIOAllocationInfo
$spec.DeviceChange[0].Device.StorageIOAllocation.Shares = New-Object VMware.Vim.SharesInfo
$spec.DeviceChange[0].Device.StorageIOAllocation.Shares.Shares = 1000
$spec.DeviceChange[0].Device.StorageIOAllocation.Shares.Level = 'normal'
$spec.DeviceChange[0].Device.StorageIOAllocation.Limit = -1
$spec.DeviceChange[0].Device.Backing = New-Object VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo
$spec.DeviceChange[0].Device.Backing.CompatibilityMode = 'physicalMode'
$spec.DeviceChange[0].Device.Backing.FileName = ''
$spec.DeviceChange[0].Device.Backing.DiskMode = 'independent_persistent'
$spec.DeviceChange[0].Device.Backing.Sharing = 'sharingMultiWriter'
#Device name is in the format /vmfs/devices/disks/naa.<LUN ID>
$spec.DeviceChange[0].Device.Backing.DeviceName = $DeviceName
#Controller key to be retrieved at run time using controller bus number
$spec.DeviceChange[0].Device.ControllerKey = $ControllerKey
#Unit number is the controller port and will be provided by SCSiFreePorts function
$spec.DeviceChange[0].Device.UnitNumber = $UnitNumber
# $SIZE is available in objects returned by GetVMCustomObject, size will be in MB 
$spec.DeviceChange[0].Device.CapacityInKB = $Size*1204
$spec.DeviceChange[0].Device.DeviceInfo = New-Object VMware.Vim.Description
$spec.DeviceChange[0].Device.DeviceInfo.Summary = 'New Hard disk'
$spec.DeviceChange[0].Device.DeviceInfo.Label = 'New Hard disk'
$spec.DeviceChange[0].Device.Key = -101
$spec.DeviceChange[0].Operation = 'add'
return $VirtualMachine.ExtensionData.ReconfigVM_Task($spec)
}

function ShareRDM {
    param (
        $VirtualMachine,
        [String]$FileName,
        [Int]$ControllerKey,
        [Int]$UnitNumber,
        [Int]$Size
    )
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.DeviceChange = @()
$spec.DeviceChange += New-Object VMware.Vim.VirtualDeviceConfigSpec
$spec.DeviceChange[0] = New-Object VMware.Vim.VirtualDeviceConfigSpec
$spec.DeviceChange[0].Device = New-Object VMware.Vim.VirtualDisk
# $SIZE is available in objects returned by GetVMCustomObject, size will be in MB 
$spec.DeviceChange[0].Device.CapacityInBytes = $Size*1204*1024*1024
$spec.DeviceChange[0].Device.StorageIOAllocation = New-Object VMware.Vim.StorageIOAllocationInfo
$spec.DeviceChange[0].Device.StorageIOAllocation.Shares = New-Object VMware.Vim.SharesInfo
$spec.DeviceChange[0].Device.StorageIOAllocation.Shares.Shares = 1000
$spec.DeviceChange[0].Device.StorageIOAllocation.Shares.Level = 'normal'
$spec.DeviceChange[0].Device.StorageIOAllocation.Limit = -1
$spec.DeviceChange[0].Device.Backing = New-Object VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo
#FileName is the disk filename to be shared in [<Datastore name>] VM Name/disk name.vmdk, to be retrieved at runtime using vm view and device bus number and Unit number
$spec.DeviceChange[0].Device.Backing.FileName = $FileName
$spec.DeviceChange[0].Device.Backing.DiskMode = 'persistent'
$spec.DeviceChange[0].Device.Backing.Sharing = 'sharingMultiWriter'
#Controller key to be retrieved at run time using controller bus number
$spec.DeviceChange[0].Device.ControllerKey = $ControllerKey
#Unit number is the controller port and will be provided by SCSiFreePorts function
$spec.DeviceChange[0].Device.UnitNumber = $UnitNumber
# $SIZE is available in objects returned by GetVMCustomObject, size will be in MB 
$spec.DeviceChange[0].Device.CapacityInKB = $Size*1204*1024
$spec.DeviceChange[0].Device.DeviceInfo = New-Object VMware.Vim.Description
$spec.DeviceChange[0].Device.DeviceInfo.Summary = 'New Hard disk'
$spec.DeviceChange[0].Device.DeviceInfo.Label = 'New Hard disk'
$spec.DeviceChange[0].Device.Key = -101
$spec.DeviceChange[0].Operation = 'add'
return $VirtualMachine.ExtensionData.ReconfigVM_Task($spec)
}

$PrimaryVirtualMachine = Get-VM -Name $PrimaryVirtualMachineName
if($PrimaryVirtualMachine.PowerState -ne 'PoweredOff')
{
    Read-Host -Prompt $PrimaryVirtualMachineName' is not Powered Off. Make sure all the Virtual Machines are Powered Off before running the script again. Press any key to exit.'
    Exit
}
$SecondaryVirtualMachines = @()
foreach($VM in $SecondaryVirtualMachinesName)
{
    $SecondaryVM = Get-VM -name $VM
    if($SecondaryVM.PowerState -ne 'PoweredOff')
{
    Read-Host -Prompt $VM' is not Powered Off. Make sure all the Virtual Machines are Powered Off before running the script again. Press any key to exit.'
    Exit
}
    $SecondaryVirtualMachines += $SecondaryVM
}

$AttachedDisks = $PrimaryVirtualMachine | Get-HardDisk
if(($AttachedDisks.Count+$RDMS.count) -gt 60)
{
    Read-Host -Prompt 'Configuration maximum for disks reached. Can not attach all provided disks. Press any key to exit.'
    exit
}

$RDMS = Get-Content -path $PathtoRDMfile
$DeviceObjects = GetVMCustomObject -VirtualMachine $PrimaryVirtualMachine -RDMS $RDMS
$PortsAvailable = SCSiFreePorts -RequiredPorts $RDMS.Count -PrimaryVirtualMachine $PrimaryVirtualMachine -SecondaryVirtualMachines $SecondaryVirtualMachines

for($i = 0; $i -lt $RDMS.Count; $i++)
{
    $CurrentObject = $DeviceObjects[$i]
    $PorttoUse = $PortsAvailable[$i]
    $CurrentObject.UnitNumber = $PorttoUse.PortNumber
    $CurrentObject.BusNumber = $PorttoUse.BusNumber
}

foreach($DiskObject in $DeviceObjects)
{
    $Controller = Get-ScsiController -VM $PrimaryVirtualMachine | ? {$_.ExtensionData.BusNumber -eq $DiskObject.BusNumber} 
    $task = AddRDM -VirtualMachine $PrimaryVirtualMachine -DeviceName $DiskObject.DeviceName -ControllerKey $Controller.ExtensionData.Key -UnitNumber $DiskObject.UnitNumber -Size $DiskObject.SizeMB
    Start-Sleep -Seconds 5
    $PVM = Get-VM -Name $PrimaryVirtualMachineName
    $Disk = $PVM.ExtensionData.Config.Hardware.Device | ? {($_.UnitNumber -eq $DiskObject.UnitNumber) -and ($_.ControllerKey -eq $Controller.ExtensionData.Key)}
    $DiskObject.FileName = $Disk.Backing.FileName
    foreach($VM in $SecondaryVirtualMachines)
    {
        $SController = Get-ScsiController -VM $PrimaryVirtualMachine | ? {$_.ExtensionData.BusNumber -eq $DiskObject.BusNumber}
        ShareRDM -VirtualMachine $VM -FileName $Disk.Backing.FileName -ControllerKey $SController.ExtensionData.Key -UnitNumber $DiskObject.UnitNumber -Size $DiskObject.SizeMB

    }

}
Write-Host "RDM's have been added on All VirtualMachines with Below Details"
Write-Host $DeviceObjects | Select NAAID,BusNumber,UnitNumber