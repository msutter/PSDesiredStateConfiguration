# A global variable that contains localized messages.
data LocalizedData
{
# culture="en-US"
ConvertFrom-StringData @'
GroupWithName=Group: {0}
RemoveOperation=Remove
AddOperation=Add
SetOperation=Set
ConfigurationStarted=Configuration of group {0} started.
ConfigurationCompleted=Configuration of group {0} completed successfully.
GroupCreated=Group {0} created successfully.
GroupUpdated=Group {0} properties updated successfully.
GroupRemoved=Group {0} removed successfully.
NoConfigurationRequired=Group {0} exists on this node with the desired properties. No action required.
NoConfigurationRequiredGroupDoesNotExist=Group {0} does not exist on this node. No action required.
CouldNotFindPrincipal=Could not find a principal with the provided name [{0}]
MembersAndIncludeExcludeConflict=The {0} and {1} and/or {2} parameters conflict. The {0} parameter should not be used in any conbination with the {1} and {2} parameters.
MembersIsNull=The Members parameter value is null. The {0} parameter must be provided if neither {1} nor {2} is provided.
IncludeAndExcludeConflict=The principal {0} is included in both {1} and {2} parameter values. The same principal must not be included in both {1} and {2} parameter values.
InvalidGroupName=The name {0} cannot be used. Names may not consist entirely of periods and/or spaces, or contain these characters: {1}
GroupExists=A group with the name {0} exists.
GroupDoesNotExist=A group with the name {0} does not exist.
PropertyMismatch=The value of the {0} property is expected to be {1} but it is {2}.
MembersNumberMismatch=Property {0}. The number of provided unique group members {1} is different from the number of actual group members {2}.
MembersMemberMismatch=At least one member {0} of the provided {1} parameter does not have a match in the existing group {2}.
MemberToExcludeMatch=At least one member {0} of the provided {1} parameter has a match in the existing group {2}.
'@
}

Add-Type -AssemblyName 'System.DirectoryServices.AccountManagement'
Import-LocalizedData LocalizedData -FileName MSFT_GroupResource.strings.psd1

<#
.Synopsys
The Get-TargetResource cmdlet.
#>
function Get-TargetResource
{
	param
	(
		[parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.String]
		$GroupName
	)

    Set-StrictMode -Version Latest

    ValidateGroupName -GroupName $GroupName
   
    # Try to find a group by its name.
    $principalContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList ([System.DirectoryServices.AccountManagement.ContextType]::Machine)
    $group = $null

    try
    {
        $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($principalContext, $GroupName);
        if($group -ne $null)
        {
            # The group is found. Enumerate all group members.
            $members = [String[]]@(EnumerateMembers -Group $group)

            # Return all group properties and Ensure="Present".
            $returnValue = @{
    	                        GroupName = $group.Name; 
                                Ensure = "Present";
                                Description = $group.Description;
                                Members = [System.String[]] $members;
                            }

            return $returnValue;
        }

        # The group is not found. Return Ensure=Absent.
        return @{
    	            GroupName = $GroupName; 
                    Ensure = "Absent";
                }
    }
    finally
    {
        if($group -ne $null)
        {
            $group.Dispose();
        }

        $principalContext.Dispose();
    }
}

<#
.Synopsys
The Set-TargetResource cmdlet.
#>
function Set-TargetResource
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $GroupName,

        [ValidateSet("Present", "Absent")]
        [System.String]
        $Ensure = "Present",

        [System.String]
        $Description,

        [System.String[]]
        $Members,

        [System.String[]]
        $MembersToInclude,

        [System.String[]]
        $MembersToExclude,

        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        $Credential
	)

    Set-StrictMode -Version Latest

    ValidateGroupName -GroupName $GroupName

    # Create an instance of PrincipalContext.
    $credentialPrincipalContext = $null;
    if($PSBoundParameters.ContainsKey('Credential'))
    {
        $networdCredential = $Credential.GetNetworkCredential();
        $credentialPrincipalContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList ([System.DirectoryServices.AccountManagement.ContextType]::Domain,
                                       $networdCredential.Domain, $networdCredential.UserName, $networdCredential.Password)
    }

    # Create local machine context.
    $localPrincipalContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList ([System.DirectoryServices.AccountManagement.ContextType]::Machine)
    $group = $null

    try
    {
        # Try to find a group by its name.
        $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($localPrincipalContext, $GroupName);
        if($Ensure -eq "Present")
        {
            # Ensure is set to "Present".

            $whatIfShouldProcess = $true;
            $groupExists = $false;
            $saveChanges = $false;

            if($group -eq $null)
            {
                # A group does not exist. Check WhatIf for adding a group.
                $whatIfShouldProcess = $pscmdlet.ShouldProcess($LocalizedData.GroupWithName -f $GroupName, $LocalizedData.AddOperation);
            }
            else
            {
                # A group exists.
                $groupExists = $true;

                # Check WhatIf for setting a group.
                $whatIfShouldProcess = $pscmdlet.ShouldProcess($LocalizedData.GroupWithName -f $GroupName, $LocalizedData.SetOperation);
            }

            if($whatIfShouldProcess)
            {
                if(-not $groupExists)
                {
                    # The group with the provided name does not exist. Add a new group.
                    $group = New-Object System.DirectoryServices.AccountManagement.GroupPrincipal -ArgumentList $localPrincipalContext
                    $group.Name = $GroupName;
                    $group.Save();
                }

                # Set group properties.

                if($PSBoundParameters.ContainsKey('Description') -and (-not $groupExists -or $Description -ne $group.Description))
                {
                    $group.Description = $Description;
                    $saveChanges = $true;
                }

                if($PSBoundParameters.ContainsKey('Members'))
                {
                    if($PSBoundParameters.ContainsKey('MembersToInclude') -or $PSBoundParameters.ContainsKey('MembersToExclude'))
                    {
                        # If Members are provided, Include and Exclude are not allowed.
                        ThrowInvalidArgumentError -ErrorId "GroupTestCmdlet_MembersPlusIncludeOrExcludeConflict" -ErrorMessage ($LocalizedData.MembersAndIncludeExcludeConflict -f "Members","MembersToInclude","MembersToExclude")
                    }

                    if($Members -eq $null)
                    {
                        ThrowInvalidArgumentError -ErrorId "GroupTestCmdlet_MembersIsNull" -ErrorMessage ($LocalizedData.MembersIsNull -f "Members","MembersToInclude","MembersToExclude")
                    }

                    # Remove duplicate names as strings.
                    $Members = [String[]]@(RemoveDuplicates -Members $Members);

                    # Resolve the names to actual principal objects.
                    [System.DirectoryServices.AccountManagement.Principal[]]$membersPrincipals = ResolveNamesToPrincipals -LocalPrincipalContext $localPrincipalContext -CredentialPrincipalContext $credentialPrincipalContext -ObjectNames $Members 

                    # Remove all possible duplicates.
                    [System.DirectoryServices.AccountManagement.Principal[]]$membersPrincipals = RemoveDuplicatePrincipals -Members $membersPrincipals
                    
                    # Find what group members must be deleted.
                    $objectsToRemove = @();

                    foreach($groupMember in $group.Members)
                    {
                        $groupMemberFound = $false;
                        for($m = 0; $m -lt $membersPrincipals.Count; $m++)
                        {
                            if($groupMember -eq $membersPrincipals[$m])
                            {
                                $groupMemberFound = $true;
                                break;
                            }
                        }

                        if(-not $groupMemberFound)
                        {
                            # Select this group for deletion.
                            $objectsToRemove += $groupMember;
                        }
                    }

                    # Find what group members must be added.
                    $objectsToAdd = @();

                    for($m = 0; $m -lt $membersPrincipals.Count; $m++)
                    {
                        $membersFound = $false;
                        foreach($groupMember in $group.Members)
                        {
                            if($groupMember -eq $membersPrincipals[$m])
                            {
                                $membersFound = $true;
                                break;
                            }
                        }

                        if(-not $membersFound)
                        {
                            # Select this group for addition.
                            $objectsToAdd += $membersPrincipals[$m];
                        }
                    }

                    if($objectsToAdd.Length -gt 0)
                    {
                        # Make changes to the group.
                        AddGroupMembers -Group $group -Principals $objectsToAdd
                        $saveChanges = $true;
                    }

                    if($objectsToRemove.Length -gt 0)
                    {
                        # Make changes to the group.
                        RemoveGroupMembers -Group $group -Principals $objectsToRemove

                        $saveChanges = $true;
                    }
                }
                else
                {
                    [System.DirectoryServices.AccountManagement.Principal[]]$membersToIncludePrincipals = $null;
                    [System.DirectoryServices.AccountManagement.Principal[]]$membersToExcludePrincipals = $null;

                    if($PSBoundParameters.ContainsKey('MembersToInclude'))
                    {
                        $MembersToInclude = [String[]]@(RemoveDuplicates -Members $MembersToInclude);

                        # Resolve the names to actual principal objects.
                        $membersToIncludePrincipals = ResolveNamesToPrincipals -LocalPrincipalContext $localPrincipalContext -CredentialPrincipalContext $credentialPrincipalContext -ObjectNames $MembersToInclude 

                        # Remove all possible duplicates.
                        [System.DirectoryServices.AccountManagement.Principal[]]$membersToIncludePrincipals = RemoveDuplicatePrincipals -Members $membersToIncludePrincipals
                    }

                    if($PSBoundParameters.ContainsKey('MembersToExclude'))
                    {
                        $MembersToExclude = [String[]]@(RemoveDuplicates -Members $MembersToExclude);

                        # Resolve the names to actual principal objects.
                        $membersToExcludePrincipals = ResolveNamesToPrincipals -LocalPrincipalContext $localPrincipalContext -CredentialPrincipalContext $credentialPrincipalContext -ObjectNames $MembersToExclude 

                        # Remove all possible duplicates.
                        [System.DirectoryServices.AccountManagement.Principal[]]$membersToExcludePrincipals = RemoveDuplicatePrincipals -Members $membersToExcludePrincipals
                    }

                    if($membersToIncludePrincipals -ne $null -and $membersToExcludePrincipals -ne $null)
                    {
                        # Both MembersToInclude and MembersToExlude were provided. Check if they have common principals.
                        foreach($includePrincipal in $membersToIncludePrincipals)
                        {
                            foreach($excludePrincipal in $membersToExcludePrincipals)
                            {
                                if($includePrincipal -eq $excludePrincipal)
                                {
                                    ThrowInvalidArgumentError -ErrorId "GroupSetCmdlet_IncludeAndExcludeConflict" -ErrorMessage ($LocalizedData.IncludeAndExcludeConflict -f $includePrincipal.SamAccountName,"MembersToInclude", "MembersToExclude")
                                }
                            }
                        }
                    }

                    if($membersToIncludePrincipals -ne $null)
                    {
                        # Find what group members must be added.
                        $objectsToAdd = @();
                        for($m = 0; $m -lt $membersToIncludePrincipals.Count; $m++)
                        {
                            $membersFound = $false;
                            foreach($groupMember in $group.Members)
                            {
                                if($groupMember -eq $membersToIncludePrincipals[$m])
                                {
                                    $membersFound = $true;
                                    break;
                                }
                            }

                            if(-not $membersFound)
                            {
                                # Select this group for addition.
                                $objectsToAdd += $membersToIncludePrincipals[$m];
                            }
                        }
 
                        if($objectsToAdd.Length -gt 0)
                        {
                            # Make changes to the group.
                            AddGroupMembers -Group $group -Principals $objectsToAdd
                            $saveChanges = $true;
                        }
                    }

                    if($membersToExcludePrincipals -ne $null)
                    {
                        # Find what group members must be deleted.
                        $objectsToRemove = @();
                        for($m = 0; $m -lt $membersToExcludePrincipals.Count; $m++)
                        {
                            $groupMemberFound = $false;
                            foreach($groupMember in $group.Members)
                            {
                                if($membersToExcludePrincipals[$m] -eq $groupMember)
                                {
                                    # Select this group for deletion.
                                    $objectsToRemove += $groupMember;
                                    break;
                                }
                            }
                        }
 
                        if($objectsToRemove.Length -gt 0)
                        {
                            # Make changes to the group.
                            RemoveGroupMembers -Group $group -Principals $objectsToRemove
                            $saveChanges = $true;
                        }
                    }
                }

                if($saveChanges)
                {
                    $group.Save();

                    # Send an operation success verbose message.
                    if($groupExists)
                    {
                        Write-Verbose -Message ($LocalizedData.GroupUpdated -f $GroupName)
                    }
                    else
                    {
                        Write-Verbose -Message ($LocalizedData.GroupCreated -f $GroupName)
                    }
                }
                else
                {
                    Write-Verbose -Message ($LocalizedData.NoConfigurationRequired -f $GroupName)
                }
            }
        }
        else
        {
            # Ensure is set to "Absent".
            if($group -ne $null)
            {
                # The group exists.
                if($pscmdlet.ShouldProcess($LocalizedData.GroupWithName -f $GroupName, $LocalizedData.RemoveOperation))
                {
                    # Remove the group by the provided name.
                    $group.Delete();
                }

                Write-Verbose -Message ($LocalizedData.GroupRemoved -f $GroupName)
            }
            else
            {
                Write-Verbose -Message ($LocalizedData.NoConfigurationRequiredGroupDoesNotExist -f $GroupName)
            }
        }
    }
    finally
    {
        if($group -ne $null)
        {
            $group.Dispose();
        }

        $localPrincipalContext.Dispose();

        if($credentialPrincipalContext -ne $null)
        {
            $credentialPrincipalContext.Dispose();
        }
    }
}

<#
.Synopsys
The Test-TargetResource cmdlet is used to validate if the resource is in a state as expected in the instance document.
#>
function Test-TargetResource
{
	param
	(
		[parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.String]
		$GroupName,

        [ValidateSet("Present", "Absent")]
        [System.String]
        $Ensure = "Present",

		[System.String]
		$Description,

		[System.String[]]
		$Members,

		[System.String[]]
		$MembersToInclude,

		[System.String[]]
		$MembersToExclude,

        [ValidateNotNullOrEmpty()]
		[System.Management.Automation.PSCredential]
		$Credential
	)

    Set-StrictMode -Version Latest

    ValidateGroupName -GroupName $GroupName
    
    # Create an instance of PrincipalContext for the provided credentials.
    $credentialPrincipalContext = $null;
    if($PSBoundParameters.ContainsKey('Credential'))
    {
        $networdCredential = $Credential.GetNetworkCredential();
        $credentialPrincipalContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList ([System.DirectoryServices.AccountManagement.ContextType]::Domain,
                                       $networdCredential.Domain, $networdCredential.UserName, $networdCredential.Password)
    }
	
    # Create local machine context.
    $localPrincipalContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList ([System.DirectoryServices.AccountManagement.ContextType]::Machine)
    $group = $null

    try
    {
        $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($localPrincipalContext, $GroupName);
        if($group -eq $null)
        {
            # A group with the provided name does not exist.
            Write-Log -Message ($LocalizedData.GroupDoesNotExist -f $GroupName)

            if($Ensure -eq "Absent")
            {
                return $true;
            }
            else
            {
                return $false;
            }
        }

        # A group with the provided name exists.
        Write-Log -Message ($LocalizedData.GroupExists -f $GroupName)

        # Validate separate properties.
        if($Ensure -eq "Absent")
        {
            Write-Log -Message ($LocalizedData.PropertyMismatch -f "Ensure", "Absent", "Present")
            return $false; # The Ensure property does not match. Return $false;
        }

        if($PSBoundParameters.ContainsKey('GroupName') -and $GroupName -ne $group.SamAccountName -and $GroupName -ne $group.Sid.Value)
        {
            return $false; # The Name property does not match. Return $false;
        }

        if($PSBoundParameters.ContainsKey('Description') -and $Description -ne $group.Description)
        {
            Write-Log -Message ($LocalizedData.PropertyMismatch -f "Description", $Description, $group.Description)
            return $false; # The Description property does not match. Return $false;
        }

        if($PSBoundParameters.ContainsKey('Members'))
        {
            if($PSBoundParameters.ContainsKey('MembersToInclude') -or $PSBoundParameters.ContainsKey('MembersToExclude'))
            {
                # If Members are provided, Include and Exclude are not allowed.
                ThrowInvalidArgumentError -ErrorId "GroupTestCmdlet_MembersPlusIncludeOrExcludeConflict" -ErrorMessage ($LocalizedData.MembersAndIncludeExcludeConflict -f "Members","MembersToInclude","MembersToExclude")
            }

            if($Members -eq $null)
            {
                ThrowInvalidArgumentError -ErrorId "GroupTestCmdlet_MembersIsNull" -ErrorMessage ($LocalizedData.MembersIsNull -f "Members","MembersToInclude","MembersToExclude")
            }

            # Remove duplicate names as strings.
            $Members = [String[]]@(RemoveDuplicates -Members $Members);

            # Resolve the names to actual principal objects.
            $membersPrincipals = ResolveNamesToPrincipals -LocalPrincipalContext $localPrincipalContext -CredentialPrincipalContext $credentialPrincipalContext -ObjectNames $Members 

            # Remove all possible duplicates.
            [System.DirectoryServices.AccountManagement.Principal[]]$membersPrincipals = RemoveDuplicatePrincipals -Members $membersPrincipals

            if($membersPrincipals.Count -ne $group.Members.Count)
            {
                Write-Log -Message ($LocalizedData.MembersNumberMismatch -f "Members", $membersPrincipals.Count, $group.Members.Count)
                return $false; # The number of provided unique group members is different from the number of actual group members. Return $false.
            }

            # Compare two members lists.
            for($m = 0; $m -lt $membersPrincipals.Count; $m++)
            {
                 $matchFound = $false;
                 foreach($groupMember in $group.Members)
                 {
                    if($membersPrincipals[$m] -eq $groupMember)
                    {
                        $matchFound = $true;
                        break;
                    }
                 }

                 if(!$matchFound)
                 {
                    Write-Log -Message ($LocalizedData.MembersMemberMismatch -f $membersPrincipals[$m].SamAccountName, "Members", $group.SamAccountName)
                    return $false; # At least one element does not have a match. Return $false;
                 }
            }
        }
        else
        {
            if($PSBoundParameters.ContainsKey('MembersToInclude'))
            {
                $MembersToInclude = [String[]]@(RemoveDuplicates -Members $MembersToInclude);

                # Resolve the names to actual principal objects.
                $membersToIncludePrincipals = ResolveNamesToPrincipals -LocalPrincipalContext $localPrincipalContext -CredentialPrincipalContext $credentialPrincipalContext -ObjectNames $MembersToInclude 

                # Remove all possible duplicates.
                [System.DirectoryServices.AccountManagement.Principal[]]$membersToIncludePrincipals = RemoveDuplicatePrincipals -Members $membersToIncludePrincipals

                # Check if every element in $membersToIncludePrincipals has a match in $group.Members.
                for($m = 0; $m -lt $membersToIncludePrincipals.Count; $m++)
                {
                     $matchFound = $false;
                     foreach($groupMember in $group.Members)
                     {
                        if($membersToIncludePrincipals[$m] -eq $groupMember)
                        {
                            $matchFound = $true;
                            break;
                        }
                     }

                     if(!$matchFound)
                     {
                        Write-Log -Message ($LocalizedData.MembersMemberMismatch -f $membersToIncludePrincipals[$m].SamAccountName, "MembersToInclude", $group.SamAccountName)
                        return $false; # At least one element from $MembersToInclude does not have a match. Return $false;
                     }
                }
            }

            if($PSBoundParameters.ContainsKey('MembersToExclude'))
            {
                $MembersToExclude = [String[]]@(RemoveDuplicates -Members $MembersToExclude);

                # Resolve the names to actual principal objects.
                $membersToExcludePrincipals = ResolveNamesToPrincipals -LocalPrincipalContext $localPrincipalContext -CredentialPrincipalContext $credentialPrincipalContext -ObjectNames $MembersToExclude 

                # Remove all possible duplicates.
                [System.DirectoryServices.AccountManagement.Principal[]]$membersToExcludePrincipals = RemoveDuplicatePrincipals -Members $membersToExcludePrincipals

                # Check if any element in $membersToExcludePrincipals has a match in $group.Members.
                for($m = 0; $m -lt $membersToExcludePrincipals.Count; $m++)
                {
                    foreach($groupMember in $group.Members)
                    {
                       if($membersToExcludePrincipals[$m] -eq $groupMember)
                       {
                           Write-Log -Message ($LocalizedData.MemberToExcludeMatch -f $membersToExcludePrincipals[$m].SamAccountName, "MembersToExclude", $group.SamAccountName)
                           return $false; # At least one element from $MembersToExclude has a match. Return $false;
                       }
                    }
                }
            }
        }
    }
    finally
    {
        if($group -ne $null)
        {
            $group.Dispose();
        }

        $localPrincipalContext.Dispose();
    }

    # All properties match. Return $true.
    return $true;
}

function RemoveDuplicates
{
    param
    (
        [System.String[]] $Members
    )

    Set-StrictMode -Version Latest

    $destIndex = 0;
    for([int] $sourceIndex = 0 ; $sourceIndex -lt $Members.Count; $sourceIndex++)
    {
        $matchFound = $false;
        for([int] $matchIndex = 0; $matchIndex -lt $destIndex; $matchIndex++)
        {
            if($Members[$sourceIndex] -eq $Members[$matchIndex])
            {
                # A duplicate is found. Discard the duplicate.
                $matchFound = $true;
                continue;
            }
        }

        if(!$matchFound)
        {
            $Members[$destIndex++] = $Members[$sourceIndex].ToLowerInvariant();
        }
    }

    # Create the output array.
    $destination = New-Object System.String[] -ArgumentList $destIndex

    # Copy only distinct elements from the original array to the destination array.
    [System.Array]::Copy($Members, $destination, $destIndex);

    return $destination;
}

function RemoveDuplicatePrincipals
{
    param
    (
        [System.DirectoryServices.AccountManagement.Principal[]] $Members
    )

    Set-StrictMode -Version Latest

    $destIndex = 0;
    for([int] $sourceIndex = 0 ; $sourceIndex -lt $Members.Count; $sourceIndex++)
    {
        $matchFound = $false;
        for([int] $matchIndex = 0; $matchIndex -lt $destIndex; $matchIndex++)
        {
            if($Members[$sourceIndex].ContextType -eq $Members[$matchIndex].ContextType -and
               $Members[$sourceIndex].SamAccountName -eq $Members[$matchIndex].SamAccountName)
            {
                # A duplicate is found. Discard the duplicate.
                $matchFound = $true;
                continue;
            }
        }

        if(!$matchFound)
        {
            $Members[$destIndex++] = $Members[$sourceIndex];
        }
    }

    # Create the output array.
    $destination = New-Object System.DirectoryServices.AccountManagement.Principal[] -ArgumentList $destIndex

    # Copy only distinct elements from the original array to the destination array.
    [System.Array]::Copy($Members, $destination, $destIndex);

    if($destination)
    {
        return [System.DirectoryServices.AccountManagement.Principal[]]$destination;
    }

    # Return an empty array.
    return ,@($destination)
}

function EnumerateMembers
{
    param
    (
        [System.DirectoryServices.AccountManagement.GroupPrincipal] $Group
    )

    Set-StrictMode -Version Latest

    # Create the output array.
    $members = @();
    foreach($member in $group.Members)
    {
        if($member.ContextType -eq "Domain")
        {
            # Select only the first part of the full domain name.
            [String]$domainName = $member.Context.Name;
            $domainName = $domainName.Substring(0, $domainName.IndexOf('.'));

            if($member.StructuralObjectClass -eq "computer")
            {
                $members += ($domainName+'\'+$member.Name);
            }
            else
            {
                $members += ($domainName+'\'+$member.SamAccountName);
            }
        }
        else
        {
            $members += $member.Name;
        }
    }

    return $members;
}

function ResolveNamesToPrincipals
{
    param
    (
        [ValidateNotNullOrEmpty()]
        [System.DirectoryServices.AccountManagement.PrincipalContext] $LocalPrincipalContext,

        [System.DirectoryServices.AccountManagement.PrincipalContext] $CredentialPrincipalContext,
        
        [ValidateNotNull()]
        [String[]] $ObjectNames
    )

    Set-StrictMode -Version Latest

    $principals = New-Object System.Collections.ArrayList

    foreach($objectName in $ObjectNames)
    {
        # Check if the name has a domain/computer prefix.
        $backSlashIndex = $objectName.IndexOfAny('\')
        if($backSlashIndex -ne -1)
        {
            # The name has a domain/computer prefix, resolve the prefix first and then the name.
            if($objectName.StartsWith([Environment]::MachineName.ToLowerInvariant()+'\') -or 
               $objectName.StartsWith('.\'))
            {
                # Remove any prefixes.
                $objectName = $objectName.Substring($backSlashIndex+1)

                # Resolve against the local context and fail if not resolved.
                $principal = ResolveNameToPrincipal -PrincipalContext $LocalPrincipalContext -ObjectName $objectName
                if($principal -ne $null)
                {
                    $null = $principals.Add($principal)
                    continue
                }

                # The provided name does not match any User, Group, or Computer. Throw an exception.
                ThrowInvalidArgumentError -ErrorId "PrincipalNotFound_LocalMachine" -ErrorMessage ($LocalizedData.CouldNotFindPrincipal -f $objectName)
            }

            # Try to resolve againt the provided credential context.
            if($CredentialPrincipalContext -ne $null)
            {
                # Remove any prefixes.
                $objectName = $objectName.Substring($backSlashIndex+1)
                $principal = ResolveNameToPrincipal -PrincipalContext $CredentialPrincipalContext -ObjectName $objectName
                if($principal -ne $null)
                {
                    $null = $principals.Add($principal)
                    continue
                }
            }

            # The provided name does not match any User, Group, or Computer. Throw an exception.
            ThrowInvalidArgumentError -ErrorId "PrincipalNotFound_ProvidedCredential" -ErrorMessage ($LocalizedData.CouldNotFindPrincipal -f $objectName)
        }
        else
        {
            # The name does not has a domain/computer prefix, resolve the name against the local context only.
            $principal = ResolveNameToPrincipal -PrincipalContext $LocalPrincipalContext -ObjectName $objectName
            if($principal -ne $null)
            {
                $null = $principals.Add($principal)
                continue
            }

            # The provided name does not match any User, Group, or Computer. Throw an exception.
            ThrowInvalidArgumentError -ErrorId "PrincipalNotFound_NoPrefix" -ErrorMessage ($LocalizedData.CouldNotFindPrincipal -f $objectName)
        }
    }

    if($principals)
    {
        return $principals
    }

    # Return an empty array.
    return ,@($principals)
}

function ResolveNameToPrincipal
{
    param
    (
        [ValidateNotNullOrEmpty()]
        [System.DirectoryServices.AccountManagement.PrincipalContext] $PrincipalContext,
        
        [ValidateNotNull()]
        [String] $ObjectName
    )

    Set-StrictMode -Version Latest

    # Try to find a matching user principal.
    $principal = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($PrincipalContext, $objectName);

    if($principal -ne $null)
    {
        return $principal
    }
    # Try to find a matching group principal.
    $principal = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($PrincipalContext, $objectName);

    if($principal -ne $null)
    {
        return $principal
    }

    # Try to find a matching computer principal.
    if($PrincipalContext.ContextType -eq [System.DirectoryServices.AccountManagement.ContextType]::Domain)
    {
        $principal = [System.DirectoryServices.AccountManagement.ComputerPrincipal]::FindByIdentity($PrincipalContext, $objectName);
    }
    else
    {
        try
        {
            $principal = [System.DirectoryServices.AccountManagement.ComputerPrincipal]::FindByIdentity($PrincipalContext, $objectName);
        }
        catch [Exception]
        {
            # This method can throw with a particular error code if a computer is not found.
            if($_.Exception.ErrorCode -ne -2147467259)
            {
                throw $_.Exception
            }
            else
            {
                $principal = $null # Failure to find a computer principal.
            }
        }
    }

    if($principal -ne $null)
    {
        return $principal
    }

    return $null
}

function AddGroupMembers
{
    param
    (
        [System.DirectoryServices.AccountManagement.GroupPrincipal] $Group,
        
        [System.DirectoryServices.AccountManagement.Principal[]] $Principals
    )

    Set-StrictMode -Version Latest

    # Make changes to the group.
    foreach($principal in $Principals)
    {
        $group.Members.Add($principal);
    }
}

function RemoveGroupMembers
{
    param
    (
        [System.DirectoryServices.AccountManagement.GroupPrincipal] $Group,
        
        [System.DirectoryServices.AccountManagement.Principal[]] $Principals
    )

    Set-StrictMode -Version Latest

    # Make changes to the group.
    foreach($principal in $Principals)
    {
        $null = $group.Members.Remove($principal);
    }
}

<#
.Synopsis
Validates the Group name for invalid characters.
#>
function ValidateGroupName
{
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $GroupName
    )

    # Check if the name consists of only periods and/or white spaces.
    $wrongName = $true;
    for($i = 0; $i -lt $GroupName.Length; $i++)
    {
        if(-not [Char]::IsWhiteSpace($GroupName, $i) -and $GroupName[$i] -ne '.')
        {
            $wrongName = $false;
            break;
        }
    }

    $invalidChars = @('\','/','"','[',']',':','|','<','>','+','=',';',',','?','*','@')

    if($wrongName)
    {
        ThrowInvalidArgumentError -ErrorId "GroupNameHasOnlyWhiteSpacesAndDots" -ErrorMessage ($LocalizedData.InvalidGroupName -f $GroupName, [string]::Join(" ", $invalidChars))
    }

    if($GroupName.IndexOfAny($invalidChars) -ne -1)
    {
        ThrowInvalidArgumentError -ErrorId "GroupNameHasInvalidCharachter" -ErrorMessage ($LocalizedData.InvalidGroupName -f $GroupName, [string]::Join(" ", $invalidChars))
    }
}

<#
.Synopsis
Throws an argument error.
#>
function ThrowInvalidArgumentError
{
    [CmdletBinding()]
    param
    (
        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ErrorId,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ErrorMessage
    )

    $errorCategory=[System.Management.Automation.ErrorCategory]::InvalidArgument
    $exception = New-Object System.ArgumentException $ErrorMessage;
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception, $ErrorId, $errorCategory, $null
    throw $errorRecord
}

<#
.Synopsis
Writes either to Verbose or ShouldProcess channel.
#>
function Write-Log
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param
    (    
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Message
    )

    if ($PSCmdlet.ShouldProcess($Message, $null, $null))
    {
        Write-Verbose $Message        
    }    
}

Export-ModuleMember -function Get-TargetResource, Set-TargetResource, Test-TargetResource
