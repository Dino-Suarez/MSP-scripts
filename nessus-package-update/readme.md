# Update Nessus package
This script can be scheduled to run on your RHEL servers at any interval to check for a new version of the appropriate Nessus package for download. I mostly run Rocky, but others on my team run Fedora and CentOS Stream - it should work equally well for all three.

It assumes you've already configured the server as a Nessus scanner and now just need to keep the Nessus service up to date.
