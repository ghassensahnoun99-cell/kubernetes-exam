# pom.xml cible Java 17 (Spring Boot 3.3) : une JRE 11 refuse de lancer le jar
FROM eclipse-temurin:17-jre
VOLUME /tmp
EXPOSE 8081
ARG JAR_FILE=target/demo-0.0.1.jar
ADD ${JAR_FILE} app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
