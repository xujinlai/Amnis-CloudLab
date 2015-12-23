#!/usr/bin/env python

import geni.portal as portal
import geni.rspec.pg as RSpec
import geni.rspec.igext as IG
from lxml import etree as ET
import crypt
import random
import os

generator = None

# Don't want this as a param yet
TBURL = "http://www.emulab.net/downloads/openstack-setup-v17-johnsond.tar.gz"
TBCMD = "sudo mkdir -p /root/setup && sudo -H /tmp/setup/setup-driver.sh 2>&1 | sudo tee /root/setup/setup-driver.log"
TBCMD_DYNNODE = "sudo mkdir -p /root/setup && sudo -H /tmp/setup/setup-driver-add-dyn-node.sh 2>&1 | sudo tee /root/setup/setup-driver.log"
TBPATH = "/tmp"

class OSPGenerator(object):
    def __init__(self):
        #
        # Create our in-memory model of the RSpec -- the resources we're
        # going to request in our experiment, and their configuration.
        #
        self.rspec = RSpec.Request()
        
        #
        # Misc instance vars
        #
        self.params = None
        self.flatlanstrs = {}
        self.vlanstrs = {}
        self.ipdb = {}
        self.dataOffset = 10
        self.ipSubnetsUsed = 0
        self.flatlans = {}
        self.vlans = {}
        self.alllans = []
        self.computeNodeList = ""
        self.computeNodeIndex = 0
        self.mgmtlan = None
        self.generateIPs = False

        #
        # This geni-lib script is designed to run in the CloudLab Portal.
        #
        self.pc = portal.Context()

        #
        # Define *many* parameters; see the help docs in geni-lib to
        # learn how to modify.
        #
        self.pc.defineParameter("release","OpenStack Release",
                           portal.ParameterType.STRING,"kilo",[("kilo","Kilo"),("juno","Juno")],
                           longDescription="We provide either OpenStack Kilo on Ubuntu 15, or OpenStack Juno on Ubuntu 14.10.  OpenStack is installed from packages available on these distributions.")
        self.pc.defineParameter("computeNodeCount", "Number of compute nodes (at Site 1)",
                           portal.ParameterType.INTEGER, 1)
        self.pc.defineParameter("publicIPCount", "Number of public IP addresses",
                           portal.ParameterType.INTEGER, 4,
                           longDescription="Make sure to include both the number of floating IP addresses you plan to need for instances; and also for OpenVSwitch interface IP addresses.  Each OpenStack network this profile creates for you is bridged to the external, public network, so you also need a public IP address for each of those switch interfaces.  So, if you ask for one GRE tunnel network, and one flat data network (the default configuration), you would need two public IPs for switch interfaces, and then you request two additional public IPs that can be bound to instances as floating IPs.  If you ask for more networks, make sure to increase this number appropriately.")

        self.pc.defineParameter("doAptUpgrade","Upgrade OpenStack packages and dependencies to the latest versions",
                           portal.ParameterType.BOOLEAN, False,advanced=True,
                           longDescription="The default images this profile uses have OpenStack and dependent packages preloaded.  To guarantee that these scripts always work, we no longer upgrade to the latest packages by default, to avoid changes.  If you want to ensure you have the latest packages, you should enable this option -- but if there are setup failures, we can't guarantee support.  NOTE: selecting this option requires that you also select the option to update the Apt package cache!")
        self.pc.defineParameter("doAptInstall","Install required OpenStack packages and dependencies",
                           portal.ParameterType.BOOLEAN, True,advanced=True,
                           longDescription="This option allows you to tell the setup scripts not to install or upgrade any packages (other than the absolute dependencies without which the scripts cannot run).  If you start from bare images, or select a profile option that may trigger a package to be installed, we may need to install packages for you; and if you have disabled it, we might not be able to configure these features.  This option is really only for people who want to configure only the openstack packages that are already installed on their disk images, and not be surprised by package or database schema upgrades.  NOTE: this option requires that you also select the option to update the Apt package cache!")
        self.pc.defineParameter("doAptUpdate","Update the Apt package cache before installing any packages",
                           portal.ParameterType.BOOLEAN, True,advanced=True,
                           longDescription="This parameter is a bit dangerous.  We update the Apt package cache by default in case we need to install any packages (i.e., if your base image doesn't have OpenStack packages preinstalled, or is missing some package that the scripts must have).  If the cache is outdated, and Apt tries to download a package, that package version may no longer exist on the mirrors.  Only disable this option if you want to minimize the risk that currently-installed pacakges will be upgraded due to dependency pull-in.  Of course, by not updating the package cache, you may not be able to install any packages (and if these scripts need to install packages for you, they may fail!), so be careful with this option.")
        self.pc.defineParameter("fromScratch","Install OpenStack packages on a bare image",
                           portal.ParameterType.BOOLEAN,False,advanced=True,
                           longDescription="If you do not mind waiting awhile for your experiment and OpenStack instance to be available, you can select this option to start from one of our standard Ubuntu disk images; the profile setup scripts will then install all necessary packages.  NOTE: this option may only be used at x86 cluster (i.e., not the \"Utah Cluster\") for now!  NOTE: this option requires that you select both the Apt update and install package options above!")
        self.pc.defineParameter("flatDataLanCount","Number of Flat Data Networks",
                           portal.ParameterType.INTEGER,1,advanced=True,
                           longDescription="Create a number of flat OpenStack networks.  If you do not select the Multiplex Flat Networks option below, each of these networks requires a physical network interface.  If you attempt to instantiate this profile on nodes with only 1 experiment interface, and ask for more than one flat network, your profile will not instantiate correctly.  Many CloudLab nodes have only a single experiment interface.")
        self.pc.defineParameter("greDataLanCount","Number of GRE Tunnel Data Networks",
                           portal.ParameterType.INTEGER,1,advanced=True,
                           longDescription="To use GRE tunnels, you must have at least one flat data network; all tunnels are implemented using the first flat network!")
        self.pc.defineParameter("vlanDataLanCount","Number of VLAN Data Networks",
                           portal.ParameterType.INTEGER,0,advanced=True,
                           longDescription="If you want to play with OpenStack networks that are implemented using real VLAN tags, create VLAN-backed networks with this parameter.  Currently, however, you cannot combine it with Flat nor Tunnel data networks.")
        self.pc.defineParameter("vxlanDataLanCount","Number of VXLAN Data Networks",
                           portal.ParameterType.INTEGER,0,
                           longDescription="To use VXLAN networks, you must have at least one flat data network; all tunnels are implemented using the first flat network!",
                           advanced=True)

        self.pc.defineParameter("managementLanType","Management Network Type",
                           portal.ParameterType.STRING,"vpn",[("vpn","VPN"),("flat","Flat")],
                           advanced=True,longDescription="This profile creates a classic OpenStack setup, where services communicate not over the public network, but over an isolated private management network.  By default, that management network is implemented as a VPN hosted on the public network; this allows us to not use up a physical experiment network interface just to host the management network, and leaves that unused interface available for OpenStack data networks.  However, if you are using multiplexed Flat networks, you can also make this a Flat network, and it will be multiplexed along with your other flat networks---isolated by VLAN tags.  These VLAN tags are internal to CloudLab, and are invisible to OpenStack.")

        self.pc.defineParameter("multiplexFlatLans", "Multiplex Flat Networks",
                           portal.ParameterType.BOOLEAN, False,
                           longDescription="Multiplex any flat networks (i.e., management and all of the flat data networks) over physical interfaces, using VLANs.  These VLANs are invisible to OpenStack, unlike the NUmber of VLAN Data Networks option, where OpenStack assigns the real VLAN tags to create its networks.  On CloudLab, many physical machines have only a single experiment network interface, so if you want multiple flat networks, you have to multiplex.  Currently, if you select this option, you *must* specify 0 for VLAN Data Networks; we cannot support both simultaneously yet.",
                           advanced=True)

        self.pc.defineParameter("computeNodeCountSite2", "Number of compute nodes at Site 2",
                           portal.ParameterType.INTEGER, 0,advanced=True,
                           longDescription="You can add additional compute nodes from other CloudLab clusters, allowing you to experiment with remote VMs controlled from the central controller at the first site.")

        self.pc.defineParameter("ipAllocationStrategy","IP Addressing",
                           portal.ParameterType.STRING,"script",[("cloudlab","CloudLab"),("script","This Script")],
                           longDescription="Either let CloudLab auto-generate IP addresses for the nodes in your OpenStack networks, or let this script generate them.  If you include nodes at multiple sites, you must choose this script!  The default is this script, because the subnets CloudLab generates for flat networks are sized according to the number of physical nodes in your topology.  However, when the profile sets up your flat OpenStack networks, it tries to enable your VMs and physical nodes to talk to each other---so they all must be on the same subnet.  Thus, you may not have many IPs left for VMs.  However, if the script IP address generation is buggy or otherwise insufficient, you can fall back to CloudLab and see if that improves things.",
                           advanced=True)

        self.pc.defineParameter("disableSecurityGroups","Disable Security Group Enforcement",
                           portal.ParameterType.BOOLEAN,False,advanced=True,
                           longDescription="Sometimes it can be easier to play with OpenStack if you do not have to mess around with security groups at all.  This option selects a null security group driver, if set.  This means security groups are enabled, but are not enforced (we set the firewall_driver neutron option to neutron.agent.firewall.NoopFirewallDriver to accomplish this).")

        self.pc.defineParameter("enableInboundSshAndIcmp","Enable Inbound SSH and ICMP",
                           portal.ParameterType.BOOLEAN,True,advanced=True,
                           longDescription="Enable inbound SSH and ICMP into your instances in the default security group, if you have security groups enabled.")

        self.pc.defineParameter("enableNewSerialSupport","Enable new Juno serial consoles",
                           portal.ParameterType.BOOLEAN,False,advanced=True,
                           longDescription="Enable new serial console support added in Juno.  This means you can access serial consoles via web sockets from a CLI tool (not in the dashboard yet), but the serial console log will no longer be available for viewing!  Until it supports both interactivity and logging, you will have to choose.  We download software for you and create a simple frontend script on your controller node, /root/setup/novaconsole.sh , that when given the name of an instance as its sole argument, will connect you to its serial console.  The escape sequence is ~. (tilde,period), but make sure to use multiple tildes to escape through your ssh connection(s), so that those are not disconnected along with your console session.")

        self.pc.defineParameter("ceilometerUseMongoDB","Use MongoDB in Ceilometer",
                           portal.ParameterType.BOOLEAN,False,advanced=True,
                           longDescription="Use MongoDB for Ceilometer instead of MySQL (with Ubuntu 14 and Juno, we have observed crashy behavior with MongoDB, so the default is MySQL; YMMV.")

        self.pc.defineParameter("enableVerboseLogging","Enable Verbose Logging",
                           portal.ParameterType.BOOLEAN,False,advanced=True,
                           longDescription="Enable verbose logging for OpenStack components.")
        self.pc.defineParameter("enableDebugLogging","Enable Debug Logging",
                           portal.ParameterType.BOOLEAN,False,advanced=True,
                           longDescription="Enable debug logging for OpenStack components.")

        self.pc.defineParameter("controllerHost", "Name of controller node",
                           portal.ParameterType.STRING, "ctl", advanced=True,
                           longDescription="The short name of the controller node.  You shold leave this alone unless you really want the hostname to change.")
        self.pc.defineParameter("networkManagerHost", "Name of network manager node",
                           portal.ParameterType.STRING, "nm",advanced=True,
                           longDescription="The short name of the network manager (neutron) node.  You shold leave this alone unless you really want the hostname to change.")
        self.pc.defineParameter("computeHostBaseName", "Base name of compute node(s)",
                           portal.ParameterType.STRING, "cp", advanced=True,
                           longDescription="The base string of the short name of the compute nodes (node names will look like cp-1, cp-2, ... or cp-s2-1, cp-s2-2, ... (for nodes at Site 2, if you request those)).  You shold leave this alone unless you really want the hostname to change.")
        #self.pc.defineParameter("blockStorageHost", "Name of block storage server node",
        #                   portal.ParameterType.STRING, "ctl")
        #self.pc.defineParameter("objectStorageHost", "Name of object storage server node",
        #                   portal.ParameterType.STRING, "ctl")
        #self.pc.defineParameter("blockStorageNodeCount", "Number of block storage nodes",
        #                   portal.ParameterType.INTEGER, 0)
        #self.pc.defineParameter("objectStorageNodeCount", "Number of object storage nodes",
        #                   portal.ParameterType.STRING, 0)
        ###self.pc.defineParameter("adminPass","The OpenStack admin password",
        ###                   portal.ParameterType.STRING,"",advanced=True,
        ###                   longDescription="You should choose a unique password at least 8 characters long, with uppercase and lowercase characters, numbers, and special characters.  CAREFULLY NOTE this password; but if you forget, you can find it later on the experiment status page.  If you don't provide a password, it will be randomly generated, and you can find it on your experiment status page after you instantiate the profile.")

        pass

    # Assume a /16 for every network
    def get_next_ipaddr(self,lan):
        ipaddr = self.ipdb[lan]['base']
        backpart = ''

        idxlist = range(1,4)
        idxlist.reverse()
        didinc = False
        for i in idxlist:
            if self.ipdb[lan]['values'][i] is -1:
                break
            if not didinc:
                didinc = True
                self.ipdb[lan]['values'][i] += 1
                if self.ipdb[lan]['values'][i] > 254:
                    if self.ipdb[lan]['values'][i-1] is -1:
                        return ''
                    else:
                        self.ipdb[lan]['values'][i-1] += 1
                        pass
                    pass
                pass
            backpart = '.' + str(self.ipdb[lan]['values'][i]) + backpart
            pass

        return ipaddr + backpart

    def get_netmask(self,lan):
        return self.ipdb[lan]['netmask']

    def generate(self):
        #
        # Get any input parameter values that will override our defaults.
        #
        self.params = self.pc.bindParameters()

        #
        # Verify our parameters and throw errors.
        #
        ###
        ### XXX: get rid of custom root password support for now
        ###
        ###if len(self.params.adminPass) > 0:
        ###    pwel = []
        ###    up = low = num = none = total = 0
        ###    for ch in self.params.adminPass:
        ###        if ch.isupper(): up += 1
        ###        if ch.islower(): low += 1
        ###        if ch.isdigit(): num += 1
        ###        if not ch.isalpha(): none += 1
        ###        total += 1
        ###        pass
        ###    if total < 8:
        ###        pwel.append("Your password should be at least 8 characters in length!")
        ###    if up == 0 or low == 0 or num == 0 or none == 0:
        ###        pwel.append("Your password should contain a mix of lowercase, uppercase, digits, and non-alphanumeric characters!")
        ###    if self.params.adminPass == "N!ceD3m0":
        ###        pwel.append("This password cannot be used.")
        ###    for err in pwel:
        ###        self.pc.reportError(portal.ParameterError(err,['adminPass']))
        ###        pass
        ###    pass
        ###elif False:
        ####    self.pc.reportError(portal.ParameterError("You cannot set a null password!",
        ####                                         ['adminPass']))
        ###    # Generate a random password that conforms to the above requirements.
        ###    # We only generate passwds with easy nonalpha chars, but we accept any
        ###    # nonalpha char to satisfy the requirements...
        ###    nonalphaChars = [33,35,36,37,38,40,41,42,43,64,94]
        ###    upperChars = range(65,90)
        ###    lowerChars = range(97,122)
        ###    decChars = range(48,57)
        ###    random.shuffle(nonalphaChars)
        ###    random.shuffle(upperChars)
        ###    random.shuffle(lowerChars)
        ###    random.shuffle(decChars)
    
        ###    passwdList = [nonalphaChars[0],nonalphaChars[1],upperChars[0],upperChars[1],
        ###                  lowerChars[0],lowerChars[1],decChars[0],decChars[1]]
        ###    random.shuffle(passwdList)
        ###    self.params.adminPass = ''
        ###    for i in passwdList:
        ###        self.params.adminPass += chr(i)
        ###        pass
        ###    pass
        ###else:
        ###    #
        ###    # For now, let Cloudlab generate the random password for us; this will
        ###    # eventually change to the above code.
        ###    #
        ###    pass

        if self.params.computeNodeCount > 8:
            perr = portal.ParameterWarning("Are you creating a real cloud?  Otherwise, do you really need more than 8 compute nodes?  Think of your fellow users scrambling to get nodes :).",['computeNodeCount'])
            self.pc.reportWarning(perr)
            pass
        if self.params.computeNodeCountSite2 > 8:
            perr = portal.ParameterWarning("Are you creating a real cloud?  Otherwise, do you really need more than 8 compute nodes?  Think of your fellow users scrambling to get nodes :).",['computeNodeCountSite2'])
            self.pc.reportWarning(perr)
            pass
        if self.params.computeNodeCountSite2 > 0 and not self.params.multiplexFlatLans:
            perr = portal.ParameterError("If you request nodes at Site 2, you must enable multiplexing for flat lans!",['computeNodeCountSite2','multiplexFlatLans'])
            self.pc.reportError(perr)
            pass

        if self.params.fromScratch and not self.params.doAptInstall:
            perr = portal.ParameterError("You cannot start from a bare image and choose not to install any OpenStack packages!",['fromScratch','doAptInstall'])
            self.pc.reportError(perr)
            pass
        if self.params.doAptUpgrade and not self.params.doAptInstall:
            perr = portal.ParameterWarning("If you disable package installation, and request package upgrades, nothing will happen; you'll have to comb through the setup script logfiles to see what packages would have been upgraded.",['doAptUpgrade','doAptInstall'])
            self.pc.reportWarning(perr)
            pass

        if self.params.publicIPCount > 16:
            perr = portal.ParameterError("You cannot request more than 16 public IP addresses, at least not without creating your own modified version of this profile!",['publicIPCount'])
            self.pc.reportError(perr)
            pass
        if (self.params.vlanDataLanCount + self.params.vxlanDataLanCount \
            + self.params.greDataLanCount + self.params.flatDataLanCount) \
            > (self.params.publicIPCount - 1):
            perr = portal.ParameterWarning("You did not request enough public IPs to cover all your data networks and still leave you at least one floating IP; you may want to read this parameter's help documentation and change your parameters!",['publicIPCount'])
            self.pc.reportWarning(perr)
            pass

        if self.params.vlanDataLanCount > 0 and self.params.multiplexFlatLans:
            perr = portal.ParameterError("You cannot specify vlanDataLanCount > 0 and multiplexFlatLans == True !",['vlanDataLanCount','multiplexFlatLans'])
            self.pc.reportError(perr)
            pass

        if self.params.greDataLanCount > 0 and self.params.flatDataLanCount < 1:
            perr = portal.ParameterError("You must specifiy at least one flat data network to request one or more GRE data networks!",['greDataLanCount','flatDataLanCount'])
            self.pc.reportError(perr)
            pass
        if self.params.vxlanDataLanCount > 0 and self.params.flatDataLanCount < 1:
            perr = portal.ParameterError("You must specifiy at least one flat data network to request one or more VXLAN data networks!",['vxlanDataLanCount','flatDataLanCount'])
            self.pc.reportError(perr)
            pass

        if self.params.computeNodeCountSite2 > 0 and self.params.ipAllocationStrategy != "script":
            # or self.params.computeNodeCountSite3 > 0)
            badpl = ['ipAllocationStrategy']
            if self.params.computeNodeCountSite2 > 0:
                badpl.append('computeNodeCountSite2')
        #    if self.params.computeNodeCountSite3 > 0:
        #        badpl.append('computeNodeCountSite3')
            perr = portal.ParameterError("You must choose an ipAllocationStrategy of 'script' when including compute nodes at multiple sites!",
                                         badpl)
            self.pc.reportError(perr)
            self.params.ipAllocationStrategy = "script"
            pass

        if self.params.ipAllocationStrategy == 'script':
            self.generateIPs = True
        else:
            self.generateIPs = False
            pass

        #
        # Give the library a chance to return nice JSON-formatted
        # exception(s) and/or warnings; this might sys.exit().
        self.pc.verifyParameters()

        detailedParamAutoDocs = ''
        for param in self.pc._parameterOrder:
            if not self.pc._parameters.has_key(param):
                continue
            detailedParamAutoDocs += \
              """
  - *%s*

    %s
    (default value: *%s*)
              """ % (self.pc._parameters[param]['description'],self.pc._parameters[param]['longDescription'],self.pc._parameters[param]['defaultValue'])
            pass

        tourDescription = \
  "This profile provides a highly-configurable OpenStack instance with a controller, network manager, and one or more compute nodes (potentially at multiple Cloudlab sites). This profile runs x86 or ARM64 nodes. It sets up OpenStack Kilo or Juno on Ubuntu 15.04 or 14.10, and configures all OpenStack services, pulls in some VM disk images, and creates basic networks accessible via floating IPs.  You'll be able to create instances and access them over the Internet in just a few minutes. When you click the Instantiate button, you'll be presented with a list of parameters that you can change to control what your OpenStack instance will look like; **carefully** read the parameter documentation on that page (or in the Instructions) to understand the various features available to you."

        ###if not self.params.adminPass or len(self.params.adminPass) == 0:
        passwdHelp = "Your OpenStack admin and instance VM password is randomly-generated by Cloudlab, and it is: `{password-adminPass}` ."
        ###else:
        ###    passwdHelp = "Your OpenStack dashboard and instance VM password is `the one you specified in parameter selection`; hopefully you memorized or memoized it!"
        ###    pass
        passwdHelp += "  When logging in to the Dashboard, use the `admin` user; when logging into instance VMs, use the `ubuntu` user."

        tourInstructions = \
          """
### Basic Instructions
Once your experiment nodes have booted, and this profile's configuration scripts have finished configuring OpenStack inside your experiment, you'll be able to visit [the OpenStack Dashboard WWW interface](http://{host-%s}/horizon/auth/login/?next=/horizon/project/instances/) (approx. 5-15 minutes).  %s

Please wait to login to the OpenStack dashboard until the setup scripts have completed (we've seen Dashboard issues with content not appearing if you login before configuration is complete).  There are multiple ways to determine if the scripts have finished:
  - First, you can watch the experiment status page: the overall State will say \"booted (startup services are still running)\" to indicate that the nodes have booted up, but the setup scripts are still running.
  - Second, the Topology View will show you, for each node, the status of the startup command on each node (the startup command kicks off the setup scripts on each node).  Once the startup command has finished on each node, the overall State field will change to \"ready\".  If any of the startup scripts fail, you can mouse over the failed node in the topology viewer for the status code.
  - Finally, the profile configuration scripts also send you two emails: once to notify you that controller setup has started, and a second to notify you that setup has completed.  Once you receive the second email, you can login to the Openstack Dashboard and begin your work.

**NOTE:** If the web interface rejects your password or gives another error, the scripts might simply need more time to set up the backend. Wait a few minutes and try again.  If you don't receive any email notifications, you can SSH to the 'ctl' node, become root, and check the primary setup script's logfile (/root/setup/setup-controller.log).  If near the bottom there's a line that includes 'Your OpenStack instance has completed setup'), the scripts have finished, and it's safe to login to the Dashboard.

If you need to run the OpenStack CLI tools, or your own scripts that use the OpenStack APIs, you'll find authentication credentials in /root/setup/admin-openrc.sh .  Be aware that the username in this file is `adminapi`, not `admin`; this is an artifact of the days when the profile used to allow you to customize the admin password (it was necessary because the nodes did not have the plaintext password, but only the hash).

The profile's setup scripts are automatically installed on each node in `/tmp/setup` .  They execute as `root`, and keep state and downloaded files in `/root/setup/`.  More importantly, they write copious logfiles in that directory; so if you think there's a problem with the configuration, you could take a quick look through these logs --- especially `setup-controller.log` on the `ctl` node.


### Detailed Parameter Documentation
%s
        """ % (self.params.controllerHost,passwdHelp,detailedParamAutoDocs)

        #
        # Setup the Tour info with the above description and instructions.
        #  
        tour = IG.Tour()
        tour.Description(IG.Tour.TEXT,tourDescription)
        tour.Instructions(IG.Tour.MARKDOWN,tourInstructions)
        self.rspec.addTour(tour)

        #
        # Ok, get down to business -- we are going to create CloudLab
        # LANs to be used as (openstack networks), based on user's
        # parameters.  We might also generate IP addresses for the
        # nodes, so set up some quick, brutally stupid IP address
        # generation for each LAN.
        #
        if self.params.managementLanType == 'flat':
            self.ipdb['mgmt-lan'] = { 'base':'192.168','netmask':'255.255.0.0','values':[-1,-10,0,0] }
            pass
        for i in range(1,self.params.flatDataLanCount + 1):
            dlanstr = "%s-%d" % ('flat-lan',i)
            self.ipdb[dlanstr] = { 'base' : '10.%d' % (i + self.dataOffset + self.ipSubnetsUsed,),'netmask' : '255.255.0.0',
                              'values' : [-1,-1,10,0] }
            self.flatlanstrs[i] = dlanstr
            self.ipSubnetsUsed += 1
            pass
        for i in range(1,self.params.vlanDataLanCount + 1):
            dlanstr = "%s-%d" % ('vlan-lan-',i)
            self.ipdb[dlanstr] = { 'base' : '10.%d' % (i + self.dataOffset + self.ipSubnetsUsed,),'netmask' : '255.255.0.0',
                              'values' : [-1,-1,10,0] }
            self.vlanstrs[i] = dlanstr
            self.ipSubnetsUsed += 1
            pass
        for i in range(1,self.params.vxlanDataLanCount + 1):
            dlanstr = "%s-%d" % ('vxlan-lan',i)
            self.ipdb[dlanstr] = { 'base' : '10.%d' % (i + self.dataOffset + self.ipSubnetsUsed,),'netmask' : '255.255.0.0',
                              'values' : [-1,-1,10,0] }
            self.ipSubnetsUsed += 1
            pass

        #
        # Ok, actually build the data LANs now...
        #

        for i in range(1,self.params.flatDataLanCount + 1):
            datalan = RSpec.LAN(self.flatlanstrs[i])
            #datalan.bandwidth = 20000
            if self.params.multiplexFlatLans:
                datalan.link_multiplexing = True
                datalan.best_effort = True
                # Need this cause LAN() sets the link type to lan, not sure why.
                datalan.type = "vlan"
                pass
            self.flatlans[i] = datalan
            self.alllans.append(datalan)
            pass
        for i in range(1,self.params.vlanDataLanCount + 1):
            datalan = RSpec.LAN("vlan-lan-%d" % (i,))
            #datalan.bandwidth = 20000
            datalan.link_multiplexing = True
            datalan.best_effort = True
            # Need this cause LAN() sets the link type to lan, not sure why.
            datalan.type = "vlan"
            self.vlans[i] = datalan
            self.alllans.append(datalan)
            pass

        #
        # Ok, also build a management LAN if requested.  If we build
        # one, it runs over a dedicated experiment interface, not the
        # Cloudlab public control network.
        #
        if self.params.managementLanType == 'flat':
            self.mgmtlan = RSpec.LAN('mgmt-lan')
            if self.params.multiplexFlatLans:
                self.mgmtlan.link_multiplexing = True
                self.mgmtlan.best_effort = True
                # Need this cause LAN() sets the link type to lan, not sure why.
                self.mgmtlan.type = "vlan"
                pass
            pass
        else:
            self.mgmtlan = None
            pass

        #
        # Construct the disk image URNs we're going to set the various
        # nodes to load.
        #
        if self.params.release == "juno":
            image_os = 'UBUNTU14-10-64'
        else:
            image_os = 'UBUNTU15-04-64'
            pass
        if self.params.fromScratch:
            image_tag_cn = 'STD'
            image_tag_nm = 'STD'
            image_tag_cp = 'STD'
        else:
            image_tag_cn = 'OSCN'
            image_tag_nm = 'OSNM'
            image_tag_cp = 'OSCP'
            pass
        
        self.ctl_disk_image = "urn:publicid:IDN+utah.cloudlab.us+image+emulab-ops//%s-%s" % (image_os,image_tag_cn)

        #
        # Add the controller node.
        #
        controller = RSpec.RawPC(self.params.controllerHost)
        controller.Site("1")
        controller.disk_image = self.ctl_disk_image
        i = 0
        for datalan in self.alllans:
            iface = controller.addInterface("if%d" % (i,))
            datalan.addInterface(iface)
            if self.generateIPs:
                addr = RSpec.IPv4Address(self.get_next_ipaddr(datalan.client_id),
                                         self.get_netmask(datalan.client_id))
                iface.addAddress(addr)
                pass
            i += 1
            pass
        if self.mgmtlan:
            iface = controller.addInterface("ifM")
            self.mgmtlan.addInterface(iface)
            if self.generateIPs:
                addr = RSpec.IPv4Address(self.get_next_ipaddr(self.mgmtlan.client_id),
                                         self.get_netmask(self.mgmtlan.client_id))
                iface.addAddress()
                pass
            pass
        controller.addService(RSpec.Install(url=TBURL, path=TBPATH))
        controller.addService(RSpec.Execute(shell="sh",command=TBCMD))
        self.rspec.addResource(controller)

        #
        # Add the network manager (neutron) node.
        #
        networkManager = RSpec.RawPC(self.params.networkManagerHost)
        networkManager.Site("1")
        networkManager.disk_image = "urn:publicid:IDN+utah.cloudlab.us+image+emulab-ops//%s-%s" % (image_os,image_tag_nm)
        i = 0
        for datalan in self.alllans:
            iface = networkManager.addInterface("if%d" % (i,))
            datalan.addInterface(iface)
            if self.generateIPs:
                addr = RSpec.IPv4Address(self.get_next_ipaddr(datalan.client_id),
                                         self.get_netmask(datalan.client_id))
                iface.addAddress(addr)
                pass
            i += 1
            pass
        if self.mgmtlan:
            iface = networkManager.addInterface("ifM")
            self.mgmtlan.addInterface(iface)
            if self.generateIPs:
                addr = RSpec.IPv4Address(self.get_next_ipaddr(self.mgmtlan.client_id),
                                         self.get_netmask(self.mgmtlan.client_id))
                iface.addAddress(addr)
                pass
            pass
        networkManager.addService(RSpec.Install(url=TBURL, path=TBPATH))
        networkManager.addService(RSpec.Execute(shell="sh",command=TBCMD))
        self.rspec.addResource(networkManager)

        #
        # Add the compute nodes.  First we generate names for each node at each site;
        # then we create those nodes at each site.
        #
        computeNodeNamesBySite = {}
        self.computeNodeList = ""
        for i in range(1,self.params.computeNodeCount + 1):
            cpname = "%s-%d" % (self.params.computeHostBaseName,i)
            if not computeNodeNamesBySite.has_key(1):
                computeNodeNamesBySite[1] = []
                pass
            computeNodeNamesBySite[1].append(cpname)
            pass
        self.computeNodeIndex = self.params.computeNodeCount
        for i in range(1,self.params.computeNodeCountSite2 + 1):
            cpname = "%s-s2-%d" % (self.params.computeHostBaseName,i)
            if not computeNodeNamesBySite.has_key(2):
                computeNodeNamesBySite[2] = []
                pass
            computeNodeNamesBySite[2].append(cpname)
            pass

        self.computeNodeDiskImage = "urn:publicid:IDN+utah.cloudlab.us+image+emulab-ops//%s-%s" % (image_os,image_tag_cp)
        
        for (siteNumber,cpnameList) in computeNodeNamesBySite.iteritems():
            for cpname in cpnameList:
                cpnode = RSpec.RawPC(cpname)
                cpnode.Site(str(siteNumber))
                cpnode.disk_image = self.computeNodeDiskImage
                i = 0
                for datalan in self.alllans:
                    iface = cpnode.addInterface("if%d" % (i,))
                    datalan.addInterface(iface)
                    if self.generateIPs:
                        addr = RSpec.IPv4Address(self.get_next_ipaddr(datalan.client_id),
                                                 self.get_netmask(datalan.client_id))
                        iface.addAddress(addr)
                        pass
                    i += 1
                    pass
                if self.mgmtlan:
                    iface = cpnode.addInterface("ifM")
                    self.mgmtlan.addInterface(iface)
                    if self.generateIPs:
                        iface.addAddress(RSpec.IPv4Address(get_next_ipaddr(self.mgmtlan.client_id),
                                                           get_netmask(self.mgmtlan.client_id)))
                        pass
                    pass
                cpnode.addService(RSpec.Install(url=TBURL, path=TBPATH))
                cpnode.addService(RSpec.Execute(shell="sh",command=TBCMD))
                self.rspec.addResource(cpnode)
                self.computeNodeList += cpname + ' '
                pass
            pass

        for datalan in self.alllans:
            self.rspec.addResource(datalan)
        if self.mgmtlan:
            self.rspec.addResource(self.mgmtlan)
            pass

        #
        # Grab a few public IP addresses.
        #
        apool = IG.AddressPool("nm",self.params.publicIPCount)
        self.rspec.addResource(apool)
        
        parameters = OSPParameters(self)
        self.rspec.addResource(parameters)

        ###if not self.params.adminPass or len(self.params.adminPass) == 0:
        if True:
            stuffToEncrypt = OSPEmulabEncrypt(self)
            self.rspec.addResource(stuffToEncrypt)
            pass

        return self.rspec.toXMLString(True)
    
    def setComputeNodeIndex(self,idx):
        self.computeNodeIndex = idx
        pass
    
    def addNewNodes(self,count=1):
        from xml.sax.saxutils import escape
        
        retval = {}
        for i in range(self.computeNodeIndex + 1,self.computeNodeIndex + count + 1):
            nn = "%s-%d" % (self.params.computeHostBaseName,i)
            lans = []
            for datalan in self.alllans:
                lan = { 'name' : datalan.client_id }
                if self.generateIPs:
                    lan['address'] = self.get_next_ipaddr(datalan.client_id)
                    lan['netmask'] = self.get_netmask(datalan.client_id)
                    pass
                lans.append(lan)
                pass
            nd = { "diskimage" : self.computeNodeDiskImage,
                   "startup" : escape(TBCMD_DYNNODE),
                   "tarballs" : [ [ escape(TBURL), TBPATH ], ],
                   "lans" : lans,
                 }
            retval[nn] = nd
            pass
        self.computeNodeIndex += count
        return retval
    pass

class OSPEmulabEncrypt(RSpec.Resource):
    def __init__(self,ospgenerator):
        super(OSPEmulabEncrypt,self).__init__()
        self.generator = ospgenerator
        pass
    
    def _write(self, root):
        ns = "{http://www.protogeni.net/resources/rspec/ext/emulab/1}"

#        el = ET.SubElement(root,"%sencrypt" % (ns,),attrib={'name':'adminPass'})
#        el.text = self.params.adminPass
        el = ET.SubElement(root,"%spassword" % (ns,),attrib={'name':'adminPass'})
        pass
    pass

#
# Add our parameters to the request so we can get their values to our nodes.
# The nodes download the manifest(s), and the setup scripts read the parameter
# values when they run.
#
class OSPParameters(RSpec.Resource):
    def __init__(self,ospgenerator):
        super(OSPParameters,self).__init__()
        self.generator = ospgenerator
        pass

    def _write(self, root):
        ns = "{http://www.protogeni.net/resources/rspec/ext/johnsond/1}"
        paramXML = "%sparameter" % (ns,)
        
        el = ET.SubElement(root,"%sprofile_parameters" % (ns,))

        param = ET.SubElement(el,paramXML)
        param.text = 'CONTROLLER="%s"' % (self.generator.params.controllerHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'NETWORKMANAGER="%s"' % (self.generator.params.networkManagerHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'COMPUTENODES="%s"' % (self.generator.computeNodeList,)
#        param = ET.SubElement(el,paramXML)
#        param.text = 'STORAGEHOST="%s"' % (self.generator.params.blockStorageHost,)
#        param = ET.SubElement(el,paramXML)
#        param.text = 'OBJECTHOST="%s"' % (self.generator.params.objectStorageHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'DATALANS="%s"' % (' '.join(map(lambda(lan): lan.client_id,self.generator.alllans)))
        param = ET.SubElement(el,paramXML)
        param.text = 'DATAFLATLANS="%s"' % (' '.join(map(lambda(i): self.generator.flatlans[i].client_id,range(1,self.generator.params.flatDataLanCount + 1))))
        param = ET.SubElement(el,paramXML)
        param.text = 'DATAVLANS="%s"' % (' '.join(map(lambda(i): self.generator.vlans[i].client_id,range(1,self.generator.params.vlanDataLanCount + 1))))
        param = ET.SubElement(el,paramXML)
        param.text = 'DATAVXLANS="%d"' % (self.generator.params.vxlanDataLanCount,)
        param = ET.SubElement(el,paramXML)
        param.text = 'DATATUNNELS=%d' % (self.generator.params.greDataLanCount,)
        param = ET.SubElement(el,paramXML)
        if self.generator.mgmtlan:
            param.text = 'MGMTLAN="%s"' % (self.generator.mgmtlan.client_id,)
        else:
            param.text = 'MGMTLAN=""'
            pass
#        param = ET.SubElement(el,paramXML)
#        param.text = 'STORAGEHOST="%s"' % (self.generator.params.blockStorageHost,)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_INSTALL=%d' % (int(self.generator.params.doAptInstall),)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_UPGRADE=%d' % (int(self.generator.params.doAptUpgrade),)
        param = ET.SubElement(el,paramXML)
        param.text = 'DO_APT_UPDATE=%d' % (int(self.generator.params.doAptUpdate),)

###        if self.generator.params.adminPass and len(self.generator.params.adminPass) > 0:
###            random.seed()
###            salt = ""
###            schars = [46,47]
###            schars.extend(range(48,58))
###            schars.extend(range(97,123))
###            schars.extend(range(65,91))
###            for i in random.sample(schars,16):
###                salt += chr(i)
###                pass
###            hpass = crypt.crypt(self.generator.params.adminPass,'$6$%s' % (salt,))
###            param = ET.SubElement(el,paramXML)
###            param.text = "ADMIN_PASS_HASH='%s'" % (hpass,)
###            pass
###        else:
        param = ET.SubElement(el,paramXML)
        param.text = "ADMIN_PASS_HASH=''"
###            pass
        
        param = ET.SubElement(el,paramXML)
        param.text = "ENABLE_NEW_SERIAL_SUPPORT=%d" % (int(self.generator.params.enableNewSerialSupport))
        
        param = ET.SubElement(el,paramXML)
        param.text = "DISABLE_SECURITY_GROUPS=%d" % (int(self.generator.params.disableSecurityGroups))
        
        param = ET.SubElement(el,paramXML)
        param.text = "DEFAULT_SECGROUP_ENABLE_SSH_ICMP=%d" % (int(self.generator.params.enableInboundSshAndIcmp))
        
        param = ET.SubElement(el,paramXML)
        param.text = "CEILOMETER_USE_MONGODB=%d" % (int(self.generator.params.ceilometerUseMongoDB))
        
        param = ET.SubElement(el,paramXML)
        param.text = "VERBOSE_LOGGING=\"%s\"" % (str(bool(self.generator.params.enableVerboseLogging)))
        param = ET.SubElement(el,paramXML)
        param.text = "DEBUG_LOGGING=\"%s\"" % (str(bool(self.generator.params.enableDebugLogging)))

        return el
    pass

DYNSLICE_CLASS = OSPGenerator
DYNSLICE_GENERATOR = None

if __name__ == '__main__':
    generator = OSPGenerator()
    DYNSLICE_GENERATOR = generator
    rspecXML = generator.generate()
    if 'GENILIB_PORTAL_MODE' in os.environ:
        generator.pc.printRequestRSpec(generator.rspec)
    else:
        print rspecXML
    pass
