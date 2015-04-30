#!/usr/bin/perl -w
#!/usr/bin/perl

# Script distribution des ovh trunks
# > repartition des appels sur tous les trunks
# > appel d'un numero toujours sur le meme trunk

# 
# copyright original 2009 infimo sarl 
# mise à jour pour fonctionner avec postgreSQL et XIVO
#
#  Usage:
#
# Pour tester le script en ligne de commande:
# ./ovh-versfixes-trunks.pl test 0033500000000
#
# indiquera le classement des trunks (suivant leur utilisation), indiquera si le numéro a déjà été enregistré dans un trunk
# et sinon sur quel trunk il va être enregistré.
#
# > Sous FreePBX, rajouter dans [from-internal-custom] 
# include => ovh-versfixes-trunks 
# ou mieux declarer custom trunk as Local/$OUTNUM$@ovh-versfixes-trunks
# on remplacera le pattern par _X. 
# > Sous XIVO, ???

# > Sous FreePBX, création du contexte
# [ovh-versfixes-trunks]
# ; distributions des trunks ovh pour les téléphones fixes
# ; en tenant comptes de la limite de 99 numeros par trunks
# exten => _0[123459]XXXXXXXX,1,AGI(ovh-versfixes-trunks.pl,${EXTEN})
# exten => _0[123459]XXXXXXXX,n,ResetCDR()
# exten => _0[123459]XXXXXXXX,n,Set(CDR(userfield)=${OUT_${OVH1}})
# exten => _0[123459]XXXXXXXX,n,Macro(dialout-trunk,${OVH1},${EXTEN},,)
# exten => _0[123459]XXXXXXXX,n,Macro(dialout-trunk,${OVH2},${EXTEN},,)
# exten => _0[123459]XXXXXXXX,n,Macro(dialout-trunk,${OVH3},${EXTEN},,)
# exten => _0[123459]XXXXXXXX,n,Macro(outisbusy,)
# > Sous XIVO, ???
#
#
# Creation de la table ovhcalls pour XIVO dans la base asterisk
# (XIVO utilise postgreSQL par défaut. Nous allons utiliser
# ce SGBD pour gérer notre table)
#
# Se connecter à la base asterisk en ligne de commande
#	sudo -u postgres psql asterisk
#
# Créer la base ovhcalls
# 	CREATE TABLE ovhcalls (
#	number VARCHAR (40) NOT NULL,
#	trunk BIGINT NOT NULL,
#	lastchanged timestamp default NULL,
#	PRIMARY KEY (number,trunk), UNIQUE (number));
#
# Quelques explications: 
# Pourquoi choisir d'utiliser VARCHAR (40) pour stocker le numéro de téléphone ? alors qu'un BIGINT aurait fait l'affaire.
# La première raison est pour conserver le ou les zéros au début du numéro (corrigez moi si je me trompe, mais dans le cas de typage en INT
# un numéro comme 0463 deviendra 463.
# Ensuite, pour conserver une approche valide, http://www.faqs.org/rfcs/rfc2806.html, en autorisant le "+" en début de numéro international par exemple, 
# ou les espaces, caractères entres les chiffres: eg: +358-555-1234567
# Enfin, pourquoi une taille de 40 alors que 15 caractères auraient pu suffire?  (voir http://en.wikipedia.org/wiki/Telephone_number)
# En l'absence de besoin d'optimisation à ce jour, je préfère prendre large. Libre à vous d'adapter cette réservation.
#
# Pourquoi choisir lastchanged comme NULL ?
# Au tout début de mes tests, j'avais utilisé une définition "NOT NULL"
# Créé une fonction qui remplace la macro CURRENT_TIMESTAMP avec mySQL:
#	CREATE OR REPLACE FUNCTION update_changetimestamp_column()
#	RETURNS TRIGGER AS $$
# 	BEGIN
# 	    NEW.lastchanged = now(); 
#	    RETURN NEW;
#	END;
#	$$ language 'plpgsql';
#
# Rajouté un Trigger pour déclencher la fonction à chaque mise à jour
# CREATE TRIGGER update_ab_changetimestamp BEFORE UPDATE
#   ON ovhcalls FOR EACH ROW EXECUTE PROCEDURE 
#    update_changetimestamp_column();
#
# Mais malgrés tout, la mise à jour de la variable ne se faisait pas, ou pas sur toutes les entrées ...
# J'ai donc directement introduit la mise à jour du timestamp directement au script
#
# Pour fonctionner avec XIVO, il faudra installer Perl DBI module, le PostgreSQL DBD driver, Asterisk::AGI et Data::Dump
# au choix suivant les distributions linux
# perl -MCPAN -e 'install DBD::Pg" ou apt-get install libdbd-pg-perl sur Debian/Ubuntu/relative
# perl -MCPAN -e "install Asterisk::AGI"
# perl -MCPAN -e "install Data::Dump" 

use strict;
#use warnings;
#use diagnostics;


use Asterisk::AGI;
use Data::Dump 'dump';

# les trunks ovh a utiliser sont les trunks 1,2,3
# recuperer les id dans l'interface , section trunks (si url finie par OUT_4 , l'id est 4) 
# ou en debut de extensions_additional.conf: OUT_1 -> 1
my @OVHDEFINEDTRUNKS = (1,2,3);
my $DEBUG=1;


# sql support
use DBI;

my $db_host="localhost";
my $db_base="asterisk";
my $db_login="postgres";
my $db_password="postgres_password";
my $starttime = (times)[0];

### FUNCS
sub get_ovh_trunks ($)
{
	my ($number) = @_;
	my $trunk = $OVHDEFINEDTRUNKS[0];
	my $requete;
	my $sth;
	######################################################
	# Connection à la base postgreSQL
	######################################################
	my $dbh = DBI->connect("DBI:Pg:dbname=$db_base;host=$db_host","$db_login","$db_password") or    die "Echec connexion";

	######################################################
	# effacement données mois precedent
	######################################################
	$requete = "DELETE from ovhcalls where lastchanged < date(concat(to_char(now(),'YYYY-Mon-'),'01'))";
	$sth = $dbh->prepare($requete);
	$sth->execute();
	$sth->finish;

	
	######################################################
	# par defaut recuperation dest trunks les moins utilisés dans l'ordre.
	######################################################
	my @besttrunks=();
	$requete = "SELECT trunk, count(number) as mycount FROM ovhcalls group by trunk order by mycount ";
	my $array_ref = $dbh->selectcol_arrayref($requete);
	print STDERR "best trunks\n";
	dump($array_ref);
	if ( scalar @$array_ref < scalar  @OVHDEFINEDTRUNKS   )
	{
		@besttrunks = @$array_ref;
		# on complete par les trunks pas encore utilises
		foreach my $ovhtrunk (@OVHDEFINEDTRUNKS)
		{
				# si pas dans le tableau , on l'ajoute en tete pour qu'il soit utilisé de preference
				if ( ! grep { $ovhtrunk eq $_ } @besttrunks) 
				{
					unshift(@besttrunks, $ovhtrunk);
				}
		} 	
	}	
	else
	{
		@besttrunks = @$array_ref;
	}	
	print STDERR "best trunks\n";
	dump(@besttrunks);
	
	######################################################
	# recup du trunk ( ou des !! ) deja selectionné
	###################################################### 
	$requete = "SELECT trunk FROM ovhcalls WHERE number= cast ($number as varchar(40))";
	print STDERR "requete:$requete\n";
	$array_ref = $dbh->selectcol_arrayref($requete);
	print STDERR "trunks for $number\n";
	dump($array_ref);
	if( $array_ref )
	{
		foreach my $alreadyusedtrunk (@$array_ref)
		{
			print STDERR "numéro deja attribué à $alreadyusedtrunk\n";
			### Le trunk deja attribué est mis en tete pour beneficier de l'illimité
			# 1 on enleve trunk
			@besttrunks = grep { $_ != $alreadyusedtrunk } @besttrunks;
			# 2 on rajoute trunk en tete
			unshift(@besttrunks, $alreadyusedtrunk);
		}
	}
	else
	{
		# numero pas encore attribué -> c'est le trunk le moins utilisé qui sera choisi
		print STDERR "nouveau numéro $number\n";
	}

	######################################################
	#save assigned trunk
	######################################################
	$trunk=$besttrunks[0];
	# REPLACE n'existe pas avec PostgreSQL, on réalise un UPSERT en version légère
        $requete = "UPDATE ovhcalls SET trunk = $trunk, lastchanged = localtimestamp(1) WHERE number = cast ($number as varchar(40))";
	print STDERR "requete:$requete\n";
	$sth = $dbh->prepare($requete);
	$sth->execute();
	$sth->finish;
	# REPLACE
	$requete = "INSERT INTO ovhcalls (number, trunk, lastchanged) SELECT $number, $trunk, localtimestamp(1) WHERE NOT EXISTS (SELECT 1 FROM ovhcalls WHERE number = cast ($number as varchar(40)))";
	$sth->execute();
	$sth->finish;
	$dbh->disconnect;

	print STDERR "resultat:\n";
	dump(@besttrunks);	
	return @besttrunks;
}



### MAIN		
my $number;
my @ovhtrunks;									
if (@ARGV > 0 and lc($ARGV[0]) eq 'test') 
{ 
		# test from the command line
		$number = $ARGV[1];
		#recupere les trunks ovh a utiliser classé par ordre de préférence
		@ovhtrunks = get_ovh_trunks($number);
		my $duration = ((times)[0]-$starttime);
		warn sprintf("trunks ovh determiné en %.4f secondes", $duration) if $DEBUG;

} 
else 
{
	#that should be the case when it is called from asterisk
	my $AGI = new Asterisk::AGI;
	#parse info from asterisk
	my %input = $AGI->ReadParse();
	my $myself = $input{request};
	#get current local time
	my @localtime = localtime(time());
	my ($day, $hour) = (($localtime[6] - 1) % 7, $localtime[2]);
	#get number
	$number = $ARGV[0];
	
	#recupere les trunks ovh a utiliser classés par ordre de préférence
	@ovhtrunks = get_ovh_trunks($number);
	#put out some info and select provider
	my $duration = ((times)[0]-$starttime);
	warn sprintf("$myself: trunks ovh determiné en %.4f secondes", $duration) if $DEBUG;
	
	
	if (@ovhtrunks) 
	{
		if ($DEBUG) 
		{
			#put out list of available providers sorted by rate
			warn "$myself: Ordre des trunks pour $number:";
			foreach my $trunkovh (@ovhtrunks) 
			{
				warn "$myself: OUT_$trunkovh";
			}
		}
	} 
	else 
	{
		die "$myself: Erreur critique, pas de trunks" if $DEBUG;
	}
	
	# on sette ovh1,ovh2....

	my $count=0;
	foreach my $trunkovh (@ovhtrunks) 
	{
		$count++;
		$AGI->set_variable("OVH$count",$trunkovh);
		$AGI->noop("Setting OVH$count to $trunkovh");
	}

}
